# claude-wt

Claude Code 워크트리 작업 격리 도구.

Claude Code에서 **작업(주제)마다 별도 git 워크트리**를 만들어 일하고, 끝나면 PR squash 머지로 기본 브랜치에 넣은 뒤 워크트리를 지우는 체계다. 특정 프로젝트와 무관하게 어느 머신·저장소에도 적용할 수 있다.

- 사용자 전역 설정(`~/.claude`)에 도구 1개, 훅 3개, 규칙 1절을 넣으면 모든 git 저장소에 적용된다.
- 저장소마다 준비·검증 스크립트를 선택으로 둘 수 있다.
## 설치

```bash
curl -fsSL https://raw.githubusercontent.com/cineraria01/claude-wt/main/install.sh | bash
```

또는 clone 후 `bash install.sh`. 다시 실행하면 최신으로 갱신된다. 자세한 내용은 14절.

## 1. 왜 쓰나

- 여러 Claude 세션·서브에이전트가 한 폴더의 같은 파일을 동시에 고치면 서로 덮어쓴다.
- 메인 폴더(처음 clone한 폴더)는 읽기·조회·통합 전용으로 두고, 변경은 전부 워크트리에서 한다.
- 흐름: **주제 1개 = 브랜치 1개 + 워크트리 1개 → PR → 기본 브랜치에 squash 머지 → 워크트리·브랜치 삭제.**

## 2. 구성 요소

| 구분 | 위치 | 하는 일 |
|---|---|---|
| 규칙 | `~/.claude/CLAUDE.md` "작업 격리" 절 | Claude가 언제 워크트리를 쓰고 어떻게 끝내는지 |
| 도구 | `~/.claude/bin/wt` (PATH의 `wt`) | start / finish / train / verify / list / gc / overlap / claim / unclaim / claims / queue |
| 훅 | `~/.claude/hooks/wt-main-guard` | 메인 폴더의 추적 파일 Edit/Write 차단 |
| 훅 | `~/.claude/hooks/wt-remove-guard` | 다른 살아 있는 세션의 워크트리 삭제·잠금 해제 차단 |
| 훅 | `~/.claude/hooks/wt-session-status` | 세션 시작 때 반영된 워크트리 자동 정리 + 남은 워크트리 알림 |
| 저장소 파일(선택) | `.claude/wt-setup.sh` | 새 워크트리 준비(의존성 설치 등) |
| 저장소 파일(선택) | `.claude/wt-verify.sh` | finish 때 rebase 뒤 검증 |
| 저장소 파일(선택) | `.worktreeinclude` | 새 워크트리로 복사할 gitignore 파일(예 `.env`) |
| 저장소 파일(선택) | `.gitattributes`의 `merge=union` | 끝에 줄만 붙이는 공용 파일(로그 등)의 rebase 충돌 방지 |

## 3. 위치·이름 규칙

- 워크트리: `<저장소>/../<저장소이름>.wt/<슬러그>` (예: `~/code/app` → `~/code/app.wt/fix-login`)
- 브랜치: `wt/<슬러그>`, 기준: `origin/<기본 브랜치>` (원격이 없으면 로컬 `main`/`master`)
- `wt start --base v2`처럼 기준을 바꾸면 `branch.<브랜치>.wtBase`에 남고, 그 레인은 `list`·`gc`·`overlap`·`finish` 모두 그 기준으로 판정·머지된다.
- 슬러그는 영문·숫자·`. _ -`만.
- 워크트리는 `wt start` 또는 서브에이전트 `isolation: "worktree"`로만 만든다. `git worktree add` 직접 호출이나 `<저장소>.wt/` 밖 위치는 쓰지 않는다.

## 4. `wt` 명령

| 명령 | 어디서 | 동작 |
|---|---|---|
| `wt start <슬러그> [--base <브랜치>]` | 저장소 안 어디서나 | `origin/<base>` fetch → `wt/<슬러그>` 브랜치로 워크트리 생성 → `.worktreeinclude` 복사 → `.claude/wt-setup.sh` 실행 → 소유 표식 기록 → 다른 레인과 겹치는 파일 출력 → 마지막 줄에 경로 출력 |
| `wt finish [--title "..."] [--priority critical\|release\|normal] [--wait <초>]` | 워크트리 안 | 5절 순서로 머지·정리. `--priority`는 머지 대기열 등급(기본 normal), `--wait`은 차례를 기다릴 최대 시간(기본 3600초, 넘으면 종료 코드 3) |
| `wt train [--title "..."] [--priority …] [--wait <초>] <레인>...` | 저장소 안 어디서나 | 끝난 레인 여럿을 검증 한 번으로 한꺼번에 머지(5-1절). 레인은 슬러그·브랜치·워크트리 경로 |
| `wt verify` | 워크트리 안 | `.claude/wt-verify.sh` 실행. 통과하면 그 코드의 트리 해시를 기록하고, rebase 뒤에도 트리가 같으면 finish가 검증을 건너뛴다. 미커밋 변경이 있으면 거절 |
| `wt list [--conflicts]` | 저장소 안 어디서나 | 워크트리·브랜치 상태(레인마다 **자기 기준** 대비 앞선 커밋 수, `[기준 v2]`, `[<기준>에 반영됨]`, `[기준 브랜치]`, 미커밋 변경, 소유자). `--conflicts`는 레인별 예상 충돌 |
| `wt gc [--apply]` | 저장소 안 어디서나 | 자기 기준에 이미 반영된 워크트리·브랜치 정리. 기준 브랜치는 지우지 않는다(12절). 기본은 목록만 |
| `wt overlap` | 워크트리 안 | 같은 기준의 다른 레인·기준 브랜치와 **미리 합쳐 보고**(`git merge-tree`, 작업 폴더는 그대로) 실제로 충돌할 파일은 `충돌 예상`, 같은 파일이지만 줄이 안 겹치면 `겹침(자동 병합 가능)`. 다른 레인의 미커밋 변경도 포함. git 2.38 미만이면 파일 단위 겹침 |
| `wt claim [--force]` | 워크트리 안 | 재개·압축·인계 뒤 이 세션이 그 워크트리를 맡는다 |
| `wt claim <이름> [--wait <초>] [--stale <초>] [--pid <pid>] [--note <글>]` | 저장소 안 어디서나 | 기계 간 선점(6-1절). 종료 코드 0 + sha, 3 + 선점자 줄, 1 실패 |
| `wt unclaim <이름> <sha>` | 저장소 안 어디서나 | 선점이 아직 그 sha일 때만 지운다(이미 없으면 0, 다른 sha면 1) |
| `wt claims` | 저장소 안 어디서나 | origin의 선점 목록(이름·선점자·나이) |
| `wt queue [--base <브랜치>]` | 저장소 안 어디서나 | 머지 대기열 목록(6-2절): 순번·등급·host·kind·레인·나이·`[차례]`·번호표 ref·메모 |
| `wt queue enter <merge\|train\|release> [--priority …] [--wait <초>] [--pid <pid>] [--note <글>] [--base <브랜치>] [--lane <이름>]` | 저장소 안 어디서나 | 번호표를 받아 차례를 기다린다. 종료 코드 0 + 번호표 ref(차례를 쥔 채 끝남), 3 시간 초과(번호표는 지움), 1 실패 |
| `wt queue leave <번호표 ref>` | 저장소 안 어디서나 | 번호표를 지우고, 차례를 쥐고 있었으면 놓는다(이미 없으면 0) |

## 5. `wt finish` 순서

1. 미커밋 변경·진행 중 rebase가 있으면 중단. 다른 살아 있는 세션 소유면 중단(`wt claim --force` 또는 `WT_FORCE_FINISH=1` 필요).
2. 충돌 예고를 한 줄로 요약한다(다른 레인과 충돌 예상, 기준과 충돌 예상, 자동 병합 가능 겹침 개수. 자세히는 `wt overlap`).
3. GitHub 원격 + `gh`가 아니면 머지 잠금 `<git-common-dir>/wt-merge.lock`에 flock을 건다(finish·train 공용, `python3` 사용). GitHub면 잠금 대신 7번의 머지 대기열이 이 기계 안팎의 순서를 정하고, rebase·검증은 줄 밖에서 동시에 미리 한다. 동시에 끝나는 레인은 차례로 머지된다. 쥔 쪽이 살아 있는 동안은 기다리고(1분마다 안내), 쥔 쪽이 어떻게 끝나든(강제 종료 포함) OS가 잠금을 풀어 멈춘 잠금이 남지 않는다. 검증·준비 스크립트와 git·gh에는 잠금 fd를 넘기지 않는다(물려받은 데몬이 잠금을 붙들지 않게).
4. `origin/<base>`를 fetch하고(base = 그 레인의 기준), 새 커밋이 없으면 정리만 한다.
5. `origin/<base>` 위로 rebase. 충돌이면 중단 → 그 워크트리에서 풀고 `git rebase --continue` → 검증 → finish 재실행.
   - 기준이 이미 들어 있으면 rebase하지 않는다. 레인 안에 합치기 커밋이 있으면(여러 레인을 합친 통합 레인) rebase 대신 기준을 merge로 받는다. rebase는 합치기를 한 줄로 다시 쌓아 이미 푼 충돌을 또 내기 때문이다. squash 머지라 결과는 같다. merge 충돌이면 풀고 `git commit` → 검증 → finish 재실행.
6. `.claude/wt-verify.sh`가 있으면 실행. 실패하면 머지하지 않는다. rebase 뒤 트리가 `wt verify`(또는 앞선 finish)가 통과시킨 트리와 같으면 건너뛴다(`WT_FORCE_VERIFY=1`이면 늘 실행).
7. GitHub 원격 + `gh`가 있으면: **머지 번호표**(6-2절, kind `merge`, `--priority`) → 차례 기다림(1분마다 `머지 순번 k/n · 앞: <host> <레인 또는 kind>(m분째)`) → **차례를 받은 뒤 재확인**(아래) → push(`--force-with-lease`) → PR 생성(없을 때) → **squash 머지**(`--match-head-commit <검증한 커밋>`) → 상태가 `MERGED`인지 확인 → 번호표 지움 → 원격 브랜치 삭제.
   - 차례를 받은 뒤 재확인: GitHub는 같은 줄 충돌만 막으므로 기다리는 사이 앞 작업이 머지한 기준 위에 검증하지 않은 조합이 들어갈 수 있다. 그래서 차례를 받으면 `origin/<base>`를 다시 받는다. 레인이 이미 그것을 포함하면 머지한다. 움직였으면 **차례를 쥔 채** 다시 rebase(충돌이면 5번 문장으로 멈추고 번호표를 놓음) → 트리가 검증 기록과 다르면 다시 검증 → 다시 확인. 대기열 밖에서 계속 push하는 곳이 있어 5번 넘게 움직이면 "계속 움직여 머지하지 못했습니다"로 멈춘다(워크트리는 남는다). push 직전에 차례를 아직 쥐고 있는지(낡은 것으로 넘겨받히지 않았는지) 본다.
   - 차례가 `--wait`(기본 3600초) 안에 오지 않으면 종료 코드 3으로 끝난다(워크트리는 남는다). 어떻게 끝나든(실패·Ctrl-C·시간 초과) 번호표를 지운다.
   원격이 없거나 GitHub가 아니면: 로컬에서 squash 커밋 → (원격 있으면) push → 기본 브랜치 fast-forward.
8. 하네스가 건 `claude agent …` 잠금만 풀고 워크트리·로컬 브랜치 삭제.
9. 메인 폴더가 그 기준 브랜치에 있으면 `origin/<base>`로 fast-forward.

## 5-1. `wt train` — 여러 레인을 한 번에

병렬 레인이 함께 끝나면 `wt finish`는 레인마다 rebase → 전체 검증 → 머지를 잠금 안에서 차례로 돈다. 앞 레인이 기준을 바꾸니 검증 기록도 매번 빗나가 전체 검증이 레인 수만큼 돈다. `wt train`은 이것을 한 번으로 줄인다.

1. 레인을 모두 확인한다. 하나라도 안 되면 아무것도 하지 않는다: 워크트리 있음, 미커밋 변경·진행 중 rebase 없음, 다른 세션 소유·다른 세션 에이전트 잠금·`git worktree lock`(하네스 외 사유) 아님, 기준 브랜치(기본 브랜치·다른 레인의 기준·`wt.protect`·원격이 앞선 브랜치) 아님, **모두 같은 기준**. 레인은 슬러그·브랜치·워크트리 경로(실행한 폴더 기준 상대 경로 가능)로 준다.
2. (GitHub가 아니면 잠금을 한 번 잡고) `origin/<base>`에 임시 통합 워크트리(`<저장소>.wt/.train-<pid>`, detached)를 만든다.
3. 준 순서대로 레인마다 그 순간의 커밋을 `git merge --squash` → 커밋 하나(메시지는 finish의 squash 메시지와 같다). 이름이 아니라 커밋으로 쌓으므로 같은 이름의 태그와 섞이지 않는다. 충돌 나는 레인은 빼고 계속한다. 이미 기준에 들어 있는 레인은 정리만 한다.
4. 쌓은 결과에 `.worktreeinclude`·`.claude/wt-setup.sh`를 적용하고(의존성을 바꾼 레인도 그 의존성으로 검증되게) `.claude/wt-verify.sh`를 **한 번** 실행한다. 실패하면 아무것도 머지하지 않고 레인을 그대로 둔다 → 레인마다 `wt finish`로 각자 검증·머지.
5. GitHub 원격 + `gh`면 묶음 하나가 머지 번호표 하나(kind `train`, 메모에 레인 이름)로 finish와 같이 차례를 기다리고, 차례를 받으면 `origin/<base>`를 다시 받는다. 검증하는 사이 움직였으면 아무것도 push하지 않고 멈춘다(종료 코드 1, 번호표는 지움, 레인은 그대로 — `wt train`을 다시 실행하면 새 기준에 다시 쌓아 검증한다). 그대로면 통합 결과를 `wt/train-…` 브랜치로 push → PR → **rebase 머지**(`--match-head-commit`, 레인마다 커밋 하나가 그대로 남는다) → `MERGED` 확인 → 원격 브랜치 삭제. 머지가 막히면(rebase 머지 꺼짐·보호 규칙·필수 체크) PR을 닫고 브랜치를 지운 뒤 멈춘다 — 레인은 그대로이니 레인마다 `wt finish`. 원격이 없거나 GitHub가 아니면 기준 브랜치로 push·fast-forward.
6. 통합 워크트리와, 머지된 레인·이미 들어 있던 레인의 워크트리·브랜치를 지우고 메인 폴더를 fast-forward. 원격에도 있던 레인 브랜치는 내용이 기준에 다 들어 있을 때만 지운다. **쌓은 뒤 레인에 새 커밋이나 미커밋 변경이 생겼으면 그 레인은 지우지 않는다**(쌓은 부분은 들어갔고, 남은 변경은 그 워크트리에서 `wt finish`).
7. 종료 코드: 0 = 모두 머지·정리, 3 = 충돌로 뺐거나 쌓은 뒤 바뀌어 남긴 레인이 있음(목록 출력), 1 = 실패(아무것도 머지 안 함, 또는 머지 단계 오류 안내).

강제 종료로 남은 `.train-<pid>` 통합 워크트리는 그 pid가 끝났으면 `wt gc`가 지운다.

레인 하나만 끝났으면 `wt finish`를 쓴다(그쪽은 `wt verify` 기록으로 검증을 건너뛸 수 있다).

squash 커밋 메시지: 커밋이 1개면 그 메시지 그대로, 여러 개면 `--title`(없으면 첫 커밋 제목) + 각 커밋 요약 + 중복을 뺀 `Co-Authored-By`.

## 6. 세션 소유 표식

- `wt start`·`wt claim`이 `<워크트리 git-dir>/wt-owner`에 `세션ID pid 시각`을 쓴다. pid는 명령을 부른 `claude` 프로세스.
- 판정: 내 세션 ID면 `[이 세션]`, pid가 살아 있는 다른 `claude`면 `[다른 세션 사용 중]`, 죽었으면 `[주인 세션 종료됨]`.
- 서브에이전트 워크트리는 하네스가 `claude agent … (pid N …)` 사유로 git 잠금을 건다. N이 살아 있는 다른 세션이면 `[다른 세션 에이전트 실행 중]`.
- `[다른 세션 사용 중]` 워크트리는 건드리지 않는다(`finish`·`gc`도 막는다). `[주인 세션 종료됨]`이나 표식 없는 것은 내가 만든 게 아니면 사용자에게 묻는다.

## 6-1. 기계 간 선점 — `wt claim <이름>`

머지 잠금(flock)은 한 기계 안에서만 줄을 세운다. 같은 원격에 여러 기계가 머지·공개하면 원격에 둔 선점으로 줄을 세운다.

- 선점 = origin의 `refs/wt-claims/<이름>`(이름은 영문·숫자·`. _ -`). 부모 없는 빈 커밋을 `git push --force-with-lease=<ref>:`(빈 lease = 없을 때만 만들기)로 올린다. 서버가 원자적으로 판정하므로 동시에 시도해도 하나만 잡는다. 브랜치가 아니라 PR·브랜치 목록에 보이지 않는다.
- 커밋 본문 한 줄 `host=<호스트> pid=<pid> at=<UTC 시각> note=<메모>`. `--pid` 기본은 부른 쪽 pid(`$PPID`).
- 종료 코드: `0` = 잡음(표준 출력에 sha), `3` = 다른 곳이 쥐고 있음(표준 출력에 `sha=… host=… pid=… at=… note=…`), `1` = 네트워크·권한 실패, origin 없음, 잘못된 이름.
- `--wait <초>`: 그 시간까지 몇 초 간격으로 다시 시도하고, 끝내 못 잡으면 3.
- 낡은 선점은 경고 한 줄(`경고: 낡은 선점을 넘겨받습니다(<이름>): …`) 뒤 그 sha에 lease를 건 삭제로 치우고 잡는다: 커밋 시각이 `--stale <초>`(기본 10800 = 3시간)보다 오래됐거나, 같은 호스트에서 그 pid가 끝났을 때. 다른 호스트의 pid는 살았는지 알 수 없으므로 시간으로만 판정한다.
- 해제: `wt unclaim <이름> <sha>` — 원격이 아직 그 sha일 때만 lease를 건 삭제. 넘겨받힌 뒤 늦게 푸는 쪽이 남의 선점을 지우지 않는다.

저장소의 공개 스크립트처럼 기계마다 같은 일을 하면 안 되는 작업은 선점으로 감싼다. 예: 같은 버전을 두 기계가 동시에 공개하지 않게

```bash
claim=$(wt claim "release-v$version" --pid $$ --note "$(hostname -s)") || {
  rc=$?; [ $rc = 3 ] && echo "v$version 은 다른 곳이 공개 중입니다: $claim" >&2; exit 1; }
trap 'wt unclaim "release-v$version" "$claim"' EXIT
# … 빌드·태그·공개 …
```

`--pid $$`로 스크립트 자신의 pid를 남기면, 스크립트가 강제 종료된 뒤 같은 기계에서 다시 실행할 때 바로 넘겨받는다. 기본 브랜치에 직접 push하는 스크립트는 선점 대신(또는 함께) 머지 대기열(6-2절)에 줄을 서야 finish·train과 순서가 맞는다.

## 6-2. 머지 대기열 — `wt queue`

같은 원격에 여러 기계·세션이 머지·공개할 때 순서를 origin에서 정한다. finish·train(GitHub 원격 + `gh`)은 스스로 줄을 서고, 기본 브랜치에 직접 push하는 공개 스크립트 같은 외부 작업은 `wt queue enter`로 줄을 선다. GitHub가 아니거나 origin이 없으면 대기열 없이 이 기계의 flock만 쓴다.

- **번호표** = origin의 `refs/wt-queue/<기준>/<번호>`(기준의 `/`는 `_`). 번호는 `<UTC 밀리초 13자리>-<host>-<pid>`라 이름이 겹치지 않고 문자열 순서가 받은 순서다. 부모 없는 빈 커밋을 빈 lease로 만든다. 제목 한 줄 `wt-queue host=… pid=… at=… kind=merge|train|release priority=critical|release|normal lane=… note=…`.
- **순서** = 차례를 쥔 번호표가 맨 앞, 나머지는 등급(`critical` → `release` → `normal`) 다음 번호(먼저 받은 순).
- **차례 쥐기·맨 앞 보호**: 맨 앞이 된 번호표는 `refs/wt-queue/<기준>/_head`(제목 `wt-queue-head ticket=<번호>`)를 빈 lease로 만들어 차례를 쥔다. 서버가 원자적으로 판정하므로 둘이 동시에 맨 앞이라 판단해도 하나만 쥔다. 쥔 뒤에는 등급이 더 높은 번호표가 와도 그 일이 끝날 때까지 기다린다(끼어들기는 기다리는 줄 안에서만).
- **살아 있음**: 기다리는 동안과 finish·train이 차례를 쥔 동안 1분마다 번호표를 새 커밋 시각으로 다시 올린다. `wt queue enter`는 차례를 받고 끝나면 갱신을 멈춘다(그 뒤는 아래 나이로 판정).
- **낡은 번호표**: 같은 host에서 그 pid가 끝났으면 바로, 다른 host는 마지막 갱신이 merge·train 30분·release 90분보다 오래됐으면 경고 한 줄(`경고: 낡은 번호표를 지웁니다(<기준>/<번호>): …`) 뒤 그 sha에 lease를 건 삭제. 차례를 쥔 번호표도 같다. `_head`가 가리키는 번호표가 없어지면 `_head`도 지운다(차례가 풀린다).
- 기다리는 쪽은 1분마다 `▸ 머지 순번 k/n · 앞: <host> <레인 또는 kind>(m분째)`를 낸다.
- 브랜치가 아니므로 PR·브랜치 목록에 보이지 않는다. `wt queue`로 본다:

```
머지 대기열 main:
  1. release  build-host  release  (12분째) [차례]  refs/wt-queue/main/1760…-build-host-4242  v1.2.3 공개
  2. normal  laptop  merge wt/fix-login (3분째)  refs/wt-queue/main/1760…-laptop-777
```

### 공개 스크립트 연동

공개 스크립트는 차례를 받은 **뒤에** 기준을 받아 버전을 정하고, 기준 브랜치에 push할 때까지 차례를 쥔다. 그 사이 다른 기계의 finish·train은 줄에서 기다리므로 오래 빌드해도 마지막 push가 밀리지 않는다.

```bash
ticket=$(wt queue enter release --pid $$ --wait 3600 --note "공개 $(hostname -s)") || {
  echo "머지 대기열 차례를 받지 못했습니다(종료 코드 $?)" >&2; exit 1; }
trap 'wt queue leave "$ticket"' EXIT
git fetch origin main && git checkout --detach origin/main   # 차례를 받은 뒤에 기준을 받는다
# … 버전 결정 · 빌드 · 태그 …
git push --atomic origin HEAD:main "refs/tags/v$version"
wt queue leave "$ticket"; trap - EXIT
```

- `--pid $$`: 스크립트가 강제 종료되면 같은 기계에서는 바로, 다른 기계에서는 90분 뒤 넘겨받는다. 공개가 90분을 넘길 수 있으면 나눠서 차례를 받는다.
- 급한 수정은 `wt finish --priority critical`(기다리는 줄에서 맨 앞으로, 차례를 쥔 작업은 끝까지 둔다).

## 7. 훅 세 개

| 훅 | 이벤트 | 동작 |
|---|---|---|
| `wt-main-guard` | PreToolUse `Edit\|Write\|MultiEdit\|NotebookEdit` | 메인 폴더의 추적 파일 편집을 거부. 통과: git 밖, 연결 워크트리 안, gitignore된 파일, 커밋 없는 저장소, `git config wt.disabled true` |
| `wt-remove-guard` | PreToolUse `Bash` | `git worktree unlock\|remove\|move`나 워크트리 경로를 가리키는 `rm -r`이 다른 살아 있는 세션(에이전트 잠금 pid 또는 `wt-owner` pid)의 워크트리를 겨누면 거부. `wt finish`/`wt gc`는 스스로 판정하므로 통과 |
| `wt-session-status` | SessionStart `startup`·`resume`·`clear`·`compact` | `wt gc --apply`로 기본 브랜치에 반영된 워크트리·브랜치를 정리하고, 남은 `wt list` 결과(`[wt 관리 밖]`·`[기준 브랜치]` 제외)를 "[wt] 남아 있는 작업 워크트리·브랜치"로 알려 준다. `[오래됨]`은 사용자에게 정리 여부를 묻는다 |

- `wt-main-guard`는 Edit/Write 도구만 막는다. Bash(`sed -i`, 리다이렉트)로 우회하지 않는 것은 규칙으로 지킨다.

## 8. 저장소별 스크립트 쓰는 법

### `.claude/wt-setup.sh` — `wt start`가 새 워크트리 안에서 실행 (예시: `examples/wt-setup.sh`)

- 환경 변수 `WT_MAIN` = 메인 폴더 경로. 실패하면 start가 멈추고 워크트리는 남는다.
- 쓰임: 의존성 설치, 메인 폴더의 빌드 산출물 복사(빌드에 필요한데 gitignore된 것).

```bash
#!/usr/bin/env bash
set -euo pipefail
# 예: Node 프로젝트
[ -f package-lock.json ] && npm ci
# 예: 메인 폴더의 빌드 산출물이 있어야 빌드되는 경우
# [ -d "$WT_MAIN/dist" ] && cp -R "$WT_MAIN/dist" dist
```

### `.claude/wt-verify.sh` — `wt finish`가 rebase 뒤, push 전에 실행 (예시: `examples/wt-verify.sh`)

- 0이 아닌 종료면 머지하지 않는다.
- `wt verify`로 미리 돌려 두면, rebase 뒤 코드(트리)가 같을 때 finish가 같은 검증을 다시 돌리지 않는다. 기준이 그사이 움직여 코드가 달라졌으면 다시 돌린다.
- 병렬 레인이 차례로 머지되면 각 레인은 앞 레인이 들어간 기본 브랜치 위에서 다시 검증돼야 하므로, 저장소의 전체 검증(포맷·빌드·테스트)을 넣는다.
- 서브에이전트(`isolation: "worktree"`) 워크트리는 `wt-setup.sh`를 거치지 않으니, 필요하면 여기서도 준비물을 확인한다.

```bash
#!/usr/bin/env bash
set -euo pipefail
[ -d node_modules ] || npm ci
npm run lint
npm test
```

두 파일 모두 `chmod +x` 후 커밋한다. 없으면 그 단계는 건너뛴다. 저장소에 `.gitattributes`가 있으면 `*.sh text eol=lf`를 두어 줄바꿈 문제를 막는다.

## 9. 작업 흐름

### 시작

```bash
wt start <슬러그>          # 출력 마지막 줄이 워크트리 경로
# Claude: EnterWorktree(path=<경로>) 후 그 안에서 편집
```

- **주제가 바뀌면 새 워크트리.** 같은 주제의 후속 수정(리뷰 반영, 오타, 이어진 요청)은 같은 워크트리. 애매하면 나눈다.
- `wt start`가 보여 주는 "다른 레인이 작업 중인 파일"을 보고, 같은 파일이면 그 레인이 끝난 뒤 하거나 그 레인에 합칠지 먼저 정한다. 작업 중에는 `wt overlap`.

### 끝

```bash
git commit ...             # 저장소 검증 통과 후
wt finish --title "..."    # 워크트리 안에서
# Claude: ExitWorktree(action="keep")
```

- finish가 rebase 충돌·검증 실패로 멈추면 그 워크트리에서 고쳐 다시 실행한다. 강제 해결·검증 생략은 하지 않는다. 충돌을 풀었으면 `wt verify` → `wt finish`(같은 코드면 검증을 한 번만 돈다).
- 머지 차단(보호 규칙·필수 체크)은 사용자에게 보고한다.
- finish 뒤 원격 브랜치를 손으로 지우지 않는다(이미 지워져 있다).
- `wt-verify.sh`가 없는 저장소에서 기본 브랜치가 그사이 움직였으면 rebase 뒤 검증을 직접 다시 돌린다.

### 병렬 서브에이전트

- `isolation: "worktree"`로 띄우고, **완료 알림을 받은 뒤에만** 각 워크트리에서 `wt finish`.
- 메인 세션이 워크트리에 들어가 있는 동안 실행 중인 에이전트의 Bash가 거부될 수 있으니, 에이전트가 도는 동안에는 워크트리에 들어가지 않는다.

## 10. 워크트리를 쓰지 않는 경우

- git 밖 폴더(`~/.claude` 등), gitignore된 파일
- 조회·명령 실행만 하는 작업
- 커밋이 없는 새 저장소(첫 커밋은 메인 폴더에서)
- `git config wt.disabled true`로 제외한 저장소

## 11. 워크트리가 나누지 않는 것

- 워크트리는 **파일만** 나눈다. 포트, 실행 중인 앱, DB, 키체인 등은 공유한다. 앱 실행·실기 확인은 한 번에 하나만.
- 배포·릴리스는 머지된 메인 폴더에서 한다.

## 12. 정리와 잔재 금지

- 보고 전에 `wt list`로 내가 만든 워크트리·브랜치가 남았는지 본다. 남겨야 하면 경로·이유·다음 할 일을 보고에 적는다.
- **참고용으로 일부러 남기지 않는다.** 머지하지 않기로 한 작업(보류·철회된 시도)은 남길 내용을 계획 문서나 커밋된 문서로 옮긴 뒤 같은 작업 안에서 워크트리·브랜치를 지운다(`git worktree remove` + `git branch -D`, 이유를 보고에 적는다). "참고용 WIP 워크트리"는 다음 세션의 잔재가 된다.
- 자동 정리: 세션 시작 훅이 자기 기준에 반영된 워크트리·브랜치를 `wt gc --apply`로 지운다(다른 세션 사용 중·24시간 내 사용·미커밋 변경은 건너뜀). 기본 브랜치에 없는 커밋을 가진 채 14일(`WT_STALE_DAYS`) 넘게 방치된 항목은 `[오래됨]`으로 표시된다 — 자동 삭제하지 말고 내용을 요약해 사용자에게 정리 여부를 묻는다. `<저장소>.wt/` 밖의 워크트리(배포용 사본 등)는 `[wt 관리 밖]`으로 표시되고 알림에서 빠진다.
- **워크트리를 손으로 지우지 않는다.** `git worktree unlock/remove`, 경로 `rm -r` 대신 `wt finish`·`wt gc --apply`만 쓴다. 커밋이 없어 보여도 다른 세션 에이전트가 첫 커밋 전일 수 있다.
- `wt gc`가 건너뛰는 것: 미커밋 변경, 다른 세션 사용 중, 다른 세션 에이전트 잠금, 24시간 내 사용, 자기 기준에 없는 커밋, **기준 브랜치**(`유지(기준 브랜치)`).
- 기준 브랜치 = 기본 브랜치, 어떤 브랜치의 `wtBase` 값으로 쓰이는 브랜치, 원격에 같은 이름이 있고 원격이 로컬보다 앞선 브랜치(오래된 로컬 `v2`가 기본 브랜치에 들어 있어도 지우지 않는다), `git config wt.protect "v2 release/*"`의 공백 구분 패턴. `wt list`에는 `[기준 브랜치]`로 보이고 세션 알림에서 빠진다.
- 반영 판정은 레인마다 자기 기준(`origin/<wtBase>`, 없으면 기본 브랜치)에 대해 조상 관계, `git cherry` patch-id, `git merge-tree` 결과가 기준 트리와 같은지까지 보므로 squash 머지도 잡는다.
- `wt finish`가 아닌 방법(합본 커밋, cherry-pick, 수동 병합)으로 넣었으면 같은 작업 안에서 `git worktree remove` + `git branch -D`로 지운다.
- 남은 워크트리를 "미병합"으로 보고하기 전에 핵심 변경이 기본 브랜치에 있는지 `git log`/`git grep`으로 대조한다.

## 13. 자주 겪는 상황

| 상황 | 할 일 |
|---|---|
| 메인 폴더에서 Edit가 거부됨 | `wt start <슬러그>` 후 워크트리에서 편집 |
| 재개·압축 뒤 내 워크트리를 이어 씀 | 그 안에서 `wt claim` (주인이 끝난 게 확실할 때만 `--force`) |
| finish가 "다른 finish·train이 머지 중" | 기다린다. 쥔 쪽이 끝나면(강제 종료 포함) 바로 이어진다 |
| finish가 "머지 순번 k/n · 앞: …" | 다른 기계·세션이 머지·공개 중이다. 기다린다. 오래 멈춰 있으면 `wt queue`로 앞 번호표를 보고, 그 작업이 끝난 게 확실하면 `wt queue leave <번호표 ref>`(아니면 낡은 번호표는 30·90분 뒤 저절로 풀린다) |
| finish가 "계속 움직여 머지하지 못했습니다" | 대기열 밖에서 기준에 잇달아 push하는 곳이 있다(대기열을 쓰지 않는 스크립트 등). 잠시 뒤 `wt finish` 재실행 |
| finish가 종료 코드 3 "머지 순번을 N분 기다렸지만" | 앞 작업이 오래 걸리는 중이다. `wt queue`로 확인하고 다시 실행(`--wait <초>`로 더 기다릴 수 있다) |
| 병렬 레인이 여럿 함께 끝남 | 레인마다 finish 대신 `wt train <레인>...`(검증 한 번). 종료 코드 3이면 출력된 남은 레인을 그 워크트리에서 `wt finish` |
| finish가 rebase 충돌 | 그 워크트리에서 해결 → `git rebase --continue` → `wt verify` → finish 재실행(같은 코드면 검증 생략) |
| 다른 기준(예: `v2`)에서 작업 | `wt start <슬러그> --base v2`. finish가 v2로 머지한다. 장기 브랜치는 필요하면 `git config wt.protect v2` |
| finish가 검증 실패 | 고쳐서 커밋 → finish 재실행 |
| 한 저장소만 이 체계에서 빼기 | 그 저장소에서 `git config wt.disabled true` |
| 남은 워크트리 정리 | `wt gc`(목록) → `wt gc --apply` |

## 14. 설치·갱신·제거

### 설치되는 것

| 저장소 파일 | 설치 위치 |
|---|---|
| `bin/wt` | `~/.claude/bin/wt` |
| `hooks/wt-*` | `~/.claude/hooks/wt-*` |
| (install.sh 안) | `~/.claude/settings.json`에 훅 등록 — 기존 설정 유지, 중복 등록 안 함 |
| `rules/worktree-isolation.md` | `~/.claude/CLAUDE.md` 끝에 "작업 격리" 절 — 같은 제목 절이 있으면 건너뜀 |
| (install.sh 안) | `~/.zshrc`·`~/.bashrc`(있는 것만)에 `PATH="$HOME/.claude/bin:$PATH"` |

이미 설치된 기계에서 같은 설치 명령을 다시 돌리면 갱신이다. `wt`·훅 파일은 새 파일로 바꿔 끼우고(실행 중인 `wt`가 읽던 파일을 덮지 않는다), `settings.json`은 wt 훅이 이미 등록돼 있으면 건드리지 않는다(빠진 것만 더할 때 `.bak-<시각>`을 남기고 바꿔 끼운다). `CLAUDE.md`의 "작업 격리" 절과 셸 rc의 PATH 줄도 이미 있으면 그대로 둔다.

```bash
curl -fsSL https://raw.githubusercontent.com/cineraria01/claude-wt/main/install.sh | bash
# 또는 clone한 폴더에서: git pull && bash install.sh
```

갱신은 `wt finish`·`wt train`이 돌고 있지 않을 때 한다. 머지 순서를 기계 간 머지 선점(`merge-<기준>`)에서 머지 대기열(`refs/wt-queue/`)로 바꾼 판부터는 옛 판과 새 판이 서로 줄을 서지 않으니, 같은 원격을 쓰는 기계를 모두 함께 갱신한다. 머지 잠금이 폴더(`wt-finish.lock`)에서 flock(`wt-merge.lock`)으로 바뀐 판부터는 갱신 전에 시작된 옛 finish와 새 finish·train이 서로를 기다리지 않는다. `<git-common-dir>/wt-finish.lock` 폴더가 있으면 그 finish가 끝난 뒤 갱신한다. 갱신·설치가 끝나면 같은 제목 절이 이미 있는 `~/.claude/CLAUDE.md`는 바뀌지 않으니, `rules/worktree-isolation.md`의 새 문장을 직접 옮긴다.

바뀌는 기존 파일은 `*.bak-<시각>`으로 남긴다. 특정 버전은 `CLAUDE_WT_REF=<태그> bash install.sh`(파이프 설치면 `curl ... | CLAUDE_WT_REF=<태그> bash`).

### 필요 조건

| 항목 | 이유 |
|---|---|
| macOS 또는 Linux, bash, curl | 설치·도구 실행 |
| git **2.38 이상** | squash 반영 판정·줄 단위 충돌 예고가 `git merge-tree --write-tree`를 쓴다(미만이면 충돌 예고는 파일 단위) |
| `/usr/bin/python3` | 훅이 JSON 입출력에 쓴다. 경로가 다르면 설치가 경고하니 훅 안의 경로를 바꾼다 |
| `gh` (로그인된 상태, 선택) | GitHub 원격이면 PR 생성·squash 머지. 없거나 GitHub가 아니면 로컬 squash 후 push |
| Claude Code 프로세스 이름이 `claude` | 소유 표식이 부모 프로세스 중 `ps -o comm=`이 `claude`인 것을 찾는다. `node`로 보이는 설치라면 세션 구분이 동작하지 않는다(나머지는 동작) |
| 기본 브랜치에 머지 권한 | finish가 PR을 직접 머지한다. 보호 규칙·필수 체크가 있으면 머지 단계에서 멈추고 워크트리를 남긴다 |

### 설치 뒤

1. 새 셸을 열거나 `export PATH="$HOME/.claude/bin:$PATH"`.
2. `wt` → 사용법이 나오면 설치됨. 아무 git 저장소에서 `wt list`.
3. Claude Code 재시작. 메인 폴더에서 추적 파일을 Edit하려 하면 `wt-main-guard`가 거부해야 정상이다.
4. 저장소마다 필요하면 `examples/`를 참고해 `.claude/wt-setup.sh`·`.claude/wt-verify.sh`를 만들어 커밋한다.

### 규칙 절 갱신

`install.sh`는 CLAUDE.md에 "작업 격리" 절이 이미 있으면 건드리지 않는다. 새 규칙으로 바꾸려면 그 절을 지우고 다시 설치하거나 `rules/worktree-isolation.md` 내용으로 직접 바꾼다.

### 제거

```bash
bash uninstall.sh    # wt·훅 파일 삭제, settings.json에서 wt 훅 등록 제거
```

`~/.claude/CLAUDE.md`의 "작업 격리" 절과 셸 rc의 PATH 줄은 직접 지운다.

## 라이선스

MIT
