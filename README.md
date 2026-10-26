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
| 저장소 파일(선택) | `.claude/wt-teardown.sh` | 워크트리를 지우기 직전 정리(setup이 만든 바깥 자원) |
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
| `wt start <슬러그> [--base <브랜치>]` | 저장소 안 어디서나 | origin에 같은 `wt/<슬러그>`가 있으면 거부(다른 기계의 같은 이름 레인일 수 있음, origin을 못 보면 경고만) → `origin/<base>` fetch → `wt/<슬러그>` 브랜치로 워크트리 생성 → `.worktreeinclude` 복사 → `.claude/wt-setup.sh` 실행 → 소유 표식 기록 → 다른 레인과 겹치는 파일 출력 → 마지막 줄에 경로 출력 |
| `wt finish [--title "..."] [--priority critical\|release\|normal] [--wait <초>]` | 워크트리 안 | 5절 순서로 머지·정리. `--priority`는 머지 대기열 등급(기본 normal), `--wait`은 차례를 기다릴 최대 시간(기본 3600초, 넘으면 종료 코드 3) |
| `wt train [--title "..."] [--priority …] [--wait <초>] <레인>...` | 저장소 안 어디서나 | 끝난 레인 여럿을 검증 한 번으로 한꺼번에 머지(5-1절). 레인은 슬러그·브랜치·워크트리 경로 |
| `wt ready [--note "..."]` · `wt ready --cancel` | 워크트리 안 | rebase(기준이 움직였으면) → 검증(같은 트리면 건너뜀) → push → origin에 준비됨 표식(5-2절). 머지는 기다리지 않는다. `--cancel`은 표식을 지운다 |
| `wt flush [--base <브랜치>] [--title "..."] [--priority …] [--wait <초>]` | 저장소 안 어디서나 | origin의 준비됨 레인 전부(어느 기계 것이든)를 검증 한 번으로 머지(5-2절). 종료 코드 0 머지(또는 없음), 3 충돌로 뺀 레인 있음·대기 시간 초과, 1 실패(검증 실패면 아무것도 머지 안 함) |
| `wt verify` | 워크트리 안 | `.claude/wt-verify.sh` 실행. 통과하면 그 코드의 트리 해시를 기록하고, rebase 뒤에도 트리가 같으면 finish가 검증을 건너뛴다. 미커밋 변경이 있으면 거절 |
| `wt list [--conflicts]` | 저장소 안 어디서나 | 워크트리·브랜치 상태(레인마다 **자기 기준** 대비 앞선 커밋 수, `[기준 v2]`, `[<기준>에 반영됨]`, `[기준 브랜치]`, 미커밋 변경, 소유자). `--conflicts`는 레인별 예상 충돌. origin에 준비됨 레인이 있으면 끝에 모든 기계·기준의 준비됨 레인(`WT_NO_READY=1`이면 읽지 않음, 세션 시작 훅이 씀) |
| `wt gc [--apply]` | 저장소 안 어디서나 | 자기 기준에 이미 반영된 워크트리·브랜치 정리. 기준 브랜치는 지우지 않는다(12절). 기본은 목록만 |
| `wt overlap` | 워크트리 안 | 같은 기준의 다른 레인·기준 브랜치와 **미리 합쳐 보고**(`git merge-tree`, 작업 폴더는 그대로) 실제로 충돌할 파일은 `충돌 예상`, 같은 파일이지만 줄이 안 겹치면 `겹침(자동 병합 가능)`. 다른 레인의 미커밋 변경도 포함. git 2.38 미만이면 파일 단위 겹침 |
| `wt claim [--force]` | 워크트리 안 | 재개·압축·인계 뒤 이 세션이 그 워크트리를 맡는다 |
| `wt claim <이름> [--wait <초>] [--stale <초>] [--pid <pid>] [--note <글>]` | 저장소 안 어디서나 | 기계 간 선점(6-1절). 종료 코드 0 + sha, 3 + 선점자 줄, 1 실패 |
| `wt unclaim <이름> <sha>` | 저장소 안 어디서나 | 선점이 아직 그 sha일 때만 지운다(이미 없으면 0, 다른 sha면 1) |
| `wt claims` | 저장소 안 어디서나 | origin의 선점 목록(이름·선점자·나이) |
| `wt queue [--base <브랜치>]` | 저장소 안 어디서나 | 머지 대기열 목록(6-2절): 순번·등급·host·kind·레인·나이·`[차례]`·번호표 ref·메모. 이어서 그 기준의 준비됨 레인(5-2절): `<기준>/<슬러그>`·host·나이·`[충돌로 빠짐 …]`/`[묶음 검증 실패 …]`·메모 |
| `wt queue enter <merge\|train\|release> [--priority …] [--wait <초>] --pid <pid> [--max-hold <초>] [--note <글>] [--base <브랜치>] [--lane <이름>]` | 저장소 안 어디서나 | 번호표를 받아 차례를 기다린다. `--pid`(차례를 쥘 프로세스, 보통 스크립트의 `$$`)는 필수이고 1보다 큰 살아 있는 pid여야 한다. 종료 코드 0 + 번호표 ref(차례를 쥔 채 끝남, 그 pid가 살아 있는 동안 갱신), 3 시간 초과(번호표는 지움), 2 `--pid` 없음·잘못됨, 1 실패 |
| `wt queue leave <번호표 ref>` | 저장소 안 어디서나 | 번호표를 지우고, 차례를 쥐고 있었으면 놓는다(이미 없으면 0) |

"어디서"는 현재 폴더 기준이다. git 위치 환경 변수(`GIT_DIR`·`GIT_WORK_TREE`·`GIT_COMMON_DIR`·`GIT_INDEX_FILE`·`GIT_OBJECT_DIRECTORY`·`GIT_ALTERNATE_OBJECT_DIRECTORIES`, git 훅 안에서 부를 때 등)가 있으면 wt는 시작할 때 그것으로 저장소·워크트리를 절대 경로로 구해 그 폴더로 옮기고(이미 그 안이면 그대로, 그 안의 중첩 워크트리면 맨 위로) 변수를 지운다 — `GIT_WORK_TREE`가 있으면 그것, 없으면 git 폴더에서(워크트리 git 폴더 `<공용>/worktrees/<이름>`은 `gitdir` 파일이 가리키는 워크트리(상대 경로 포함), `core.bare`가 true면 그 폴더, `core.worktree`가 있으면(하위 모듈) 그것, 나머지는 부모). 현재 폴더가 다른 저장소의 작업 폴더 안이면 옮기지 않고 멈춘다. 대상 워크트리 안에 있는 별개 저장소(gitignore된 clone 등)에서 `GIT_DIR`로 바깥 저장소를 가리켜 불러도 같은 이유로 멈춘다. 그래서 상대 경로 `GIT_DIR`도 wt가 다른 폴더로 옮긴 뒤 깨지지 않고, `git -C <다른 워크트리>`가 엉뚱한 저장소를 보지 않는다. 저장소를 못 찾으면 오류로 끝난다. 인증 변수(`GIT_SSH_COMMAND`·`GIT_ASKPASS`·`GIT_CONFIG_*`)는 그대로 둔다.

## 5. `wt finish` 순서

1. 미커밋 변경·진행 중 rebase가 있으면 중단. 다른 살아 있는 세션 소유면 중단(`wt claim --force` 또는 `WT_FORCE_FINISH=1` 필요).
2. 충돌 예고를 한 줄로 요약한다(다른 레인과 충돌 예상, 기준과 충돌 예상, 자동 병합 가능 겹침 개수. 자세히는 `wt overlap`).
3. GitHub 원격 + `gh`가 아니면 머지 잠금 `<git-common-dir>/wt-merge.lock`에 flock을 건다(finish·train 공용, `python3` 사용). GitHub면 잠금 대신 7번의 머지 대기열이 이 기계 안팎의 순서를 정하고, rebase·검증은 줄 밖에서 동시에 미리 한다. 동시에 끝나는 레인은 차례로 머지된다. 쥔 쪽이 살아 있는 동안은 기다리고(1분마다 안내), 쥔 쪽이 어떻게 끝나든(강제 종료 포함) OS가 잠금을 풀어 멈춘 잠금이 남지 않는다. 검증·준비 스크립트와 git·gh에는 잠금 fd를 넘기지 않는다(물려받은 데몬이 잠금을 붙들지 않게).
4. `origin/<base>`를 fetch하고(base = 그 레인의 기준), 새 커밋이 없으면 정리만 한다.
5. `origin/<base>` 위로 rebase. 충돌이면 중단 → 그 워크트리에서 풀고 `git rebase --continue` → 검증 → finish 재실행.
   - 기준이 이미 들어 있으면 rebase하지 않는다. 레인 안에 합치기 커밋이 있으면(여러 레인을 합친 통합 레인) rebase 대신 기준을 merge로 받는다. rebase는 합치기를 한 줄로 다시 쌓아 이미 푼 충돌을 또 내기 때문이다. squash 머지라 결과는 같다. merge 충돌이면 풀고 `git commit` → 검증 → finish 재실행.
6. `.claude/wt-verify.sh`가 있으면 실행. 실패하면 머지하지 않는다. rebase 뒤 트리가 `wt verify`(또는 앞선 finish)가 통과시킨 트리와 같으면 건너뛴다(`WT_FORCE_VERIFY=1`이면 늘 실행).
   - 주의: GitHub 원격이면 rebase·검증을 줄 밖에서 하므로, 같은 기계에서 finish 여럿이 함께 다시 검증해야 하면 검증이 동시에 돈다. 부하에 민감한 시험이 있으면 레인을 `wt verify`로 마쳐 finish가 검증을 건너뛰게 하거나 `wt train`으로 묶는다.
7. GitHub 원격 + `gh`가 있으면(자동 묶음이 켜져 있으면 먼저 준비됨 표식을 올리고 차례에 다른 준비됨 레인과 묶는다 — 5-2절): **머지 번호표**(6-2절, kind `merge`, `--priority`) → 차례 기다림(1분마다 `머지 순번 k/n · 앞: <host> <레인 또는 kind>(m분째)`) → **차례를 받은 뒤 재확인**(아래) → push(아래 레인 브랜치 규칙) → PR 생성(없을 때) → **squash 머지**(`--match-head-commit <검증한 커밋>`) → 상태가 `MERGED`인지 확인 → 번호표 지움 → 원격 브랜치 삭제.
   - 차례를 받은 뒤 재확인: GitHub는 같은 줄 충돌만 막으므로 기다리는 사이 앞 작업이 머지한 기준 위에 검증하지 않은 조합이 들어갈 수 있다. 그래서 차례를 받으면 `origin/<base>`를 다시 받는다. 레인이 이미 그것을 포함하면 머지한다. 움직였으면 **차례를 쥔 채** 다시 rebase(충돌이면 5번 문장으로 멈추고 번호표를 놓음) → 트리가 검증 기록과 다르면 다시 검증 → 다시 확인. 대기열 밖에서 계속 push하는 곳이 있어 5번 넘게 움직이면 "계속 움직여 머지하지 못했습니다"로 멈춘다(워크트리는 남는다). push 직전에 차례를 아직 쥐고 있는지(낡은 것으로 넘겨받히지 않았는지) 본다.
   - 레인 브랜치 push: `git ls-remote`로 원격 sha를 읽는다. 없으면 빈 기대값(`--force-with-lease=<ref>:`, 없을 때만 만들기)으로 올린다. 있으면 이 레인이 마지막으로 올린 sha(`branch.<브랜치>.wtPushed`)이거나 HEAD의 조상일 때만 그 sha를 기대값으로 덮어쓴다(rebase 뒤 재푸시). 그 밖이면 다른 기계의 같은 이름 레인으로 보고 덮어쓰지 않고 멈춘다 — 새 이름으로 `wt start` 해 커밋을 옮긴 뒤 finish한다. 받아 둔 추적 ref(`origin/<브랜치>`)는 남의 것일 수 있어 기대값으로 쓰지 않는다. `wt start`를 거치지 않은 브랜치(하네스의 `worktree-agent-*` 등)도 같다. 머지 뒤 원격 브랜치 삭제도 HEAD를 기대값으로 한다.
   - 차례가 `--wait`(기본 3600초) 안에 오지 않으면 종료 코드 3으로 끝난다(워크트리는 남는다). 어떻게 끝나든(실패·Ctrl-C·시간 초과) 번호표를 지운다.
   원격이 없거나 GitHub가 아니면: 로컬에서 squash 커밋 → (원격 있으면) push → 기본 브랜치 fast-forward.
8. 하네스가 건 `claude agent …` 잠금만 풀고 `.claude/wt-teardown.sh`(있으면) 실행 → 워크트리·로컬 브랜치 삭제.
9. 메인 폴더가 그 기준 브랜치에 있으면 `origin/<base>`로 fast-forward. 머지는 이미 끝났으므로 이 단계의 받기가 실패하면 한 번 다시 시도하고, 그래도 안 되면 경고만 낸다(실패로 끝내지 않는다).

## 5-1. `wt train` — 여러 레인을 한 번에

병렬 레인이 함께 끝나면 `wt finish`는 레인마다 rebase → 전체 검증 → 머지를 잠금 안에서 차례로 돈다. 앞 레인이 기준을 바꾸니 검증 기록도 매번 빗나가 전체 검증이 레인 수만큼 돈다. `wt train`은 이것을 한 번으로 줄인다.

1. 레인을 모두 확인한다. 하나라도 안 되면 아무것도 하지 않는다: 워크트리 있음, 미커밋 변경·진행 중 rebase 없음, 다른 세션 소유·다른 세션 에이전트 잠금·`git worktree lock`(하네스 외 사유) 아님, 기준 브랜치(기본 브랜치·다른 레인의 기준·`wt.protect`·원격이 앞선 브랜치) 아님, **모두 같은 기준**. 레인은 슬러그·브랜치·워크트리 경로(실행한 폴더 기준 상대 경로 가능)로 준다.
2. (GitHub가 아니면 잠금을 한 번 잡고) `origin/<base>`에 임시 통합 워크트리(`<저장소>.wt/.train-<pid>`, detached)를 만든다.
3. 준 순서대로 레인마다 그 순간의 커밋을 `git merge --squash` → 커밋 하나(메시지는 finish의 squash 메시지와 같다). 이름이 아니라 커밋으로 쌓으므로 같은 이름의 태그와 섞이지 않는다. 충돌 나는 레인은 빼고 계속한다. 이미 기준에 들어 있는 레인은 정리만 한다.
4. 쌓은 결과에 `.worktreeinclude`·`.claude/wt-setup.sh`를 적용하고(의존성을 바꾼 레인도 그 의존성으로 검증되게) `.claude/wt-verify.sh`를 **한 번** 실행한다. 실패하면 아무것도 머지하지 않고 레인을 그대로 둔다 → 레인마다 `wt finish`로 각자 검증·머지.
5. GitHub 원격 + `gh`면 묶음 하나가 머지 번호표 하나(kind `train`, 메모에 레인 이름)로 finish와 같이 차례를 기다리고, 차례를 받으면 `origin/<base>`를 다시 받는다. 검증하는 사이 움직였으면 아무것도 push하지 않고 멈춘다(종료 코드 1, 번호표는 지움, 레인은 그대로 — `wt train`을 다시 실행하면 새 기준에 다시 쌓아 검증한다). 그대로면 통합 결과를 `wt/train-…` 브랜치로 push(빈 기대값 — 같은 이름이 있으면 멈춤) → PR → **rebase 머지**(`--match-head-commit`, 레인마다 커밋 하나가 그대로 남는다) → `MERGED` 확인 → 원격 브랜치 삭제. 머지가 막히면(rebase 머지 꺼짐·보호 규칙·필수 체크) PR을 닫고 브랜치를 지운 뒤 멈춘다 — 레인은 그대로이니 레인마다 `wt finish`. 원격이 없거나 GitHub가 아니면 기준 브랜치로 push·fast-forward.
6. 통합 워크트리와, 머지된 레인·이미 들어 있던 레인의 워크트리·브랜치를 지우고 메인 폴더를 fast-forward. 원격에도 있던 레인 브랜치는 내용이 기준에 다 들어 있을 때만 지운다. **쌓은 뒤 레인에 새 커밋이나 미커밋 변경이 생겼으면 그 레인은 지우지 않는다**(쌓은 부분은 들어갔고, 남은 변경은 그 워크트리에서 `wt finish`).
7. 종료 코드: 0 = 모두 머지·정리, 3 = 충돌로 뺐거나 쌓은 뒤 바뀌어 남긴 레인이 있음(목록 출력), 1 = 실패(아무것도 머지 안 함, 또는 머지 단계 오류 안내).

강제 종료로 남은 `.train-<pid>` 통합 워크트리는 그 pid가 끝났으면 `wt gc`가 지운다.

레인 하나만 끝났으면 `wt finish`를 쓴다(그쪽은 `wt verify` 기록으로 검증을 건너뛸 수 있다).

squash 커밋 메시지: 커밋이 1개면 그 메시지 그대로, 여러 개면 `--title`(없으면 첫 커밋 제목) + 각 커밋 요약 + 중복을 뺀 `Co-Authored-By`.

## 5-2. 묶어 머지 — `wt ready` · `wt flush` · 자동 묶음

레인 여럿이 줄을 서면 레인마다 rebase → 전체 검증 → 머지를 차례로 돈다. 그사이 다른 기계가 기준에 머지하면 다시 rebase·검증한다. N개가 줄 서면 검증이 N번 이상 돈다. 묶어 머지는 이것을 (충돌이 없으면) **한 번**으로 줄인다. `wt train`은 한 기계의 레인만 묶지만, 이것은 origin을 거쳐 **모든 기계의 레인**을 묶는다.

**준비됨 표식**: `refs/wt-ready/<기준>/<슬러그>`(origin). 레인 커밋을 부모로 하고 같은 트리를 가진 빈 커밋이며, 제목 한 줄에 `branch`·`base`·`host`·`pid`·`at`·`tree`(검증한 트리)·`state`(`ready`·`conflict`·`failed`·`merged`)·`against`(뺄 때의 기준 sha, `merged`면 머지 뒤 기준 sha)·`note`. 공개 저장소에서도 보이는 ref라 세션 ID는 싣지 않는다. 만든 지 `git config wt.readyMaxAge`(일, 기본 7)가 지난 표식은 묶지 않고 `wt list`·`wt queue`에 `[오래됨]`으로만 보인다. 표식 하나만 받으면 레인 커밋까지 오므로 다른 기계의 브랜치를 따로 받지 않는다. 만들기·바꾸기·지우기는 모두 지금 sha에 건 lease(`--force-with-lease`)라 동시에 건드려도 한쪽만 이긴다.

`wt ready` (워크트리 안): 미커밋·진행 중 rebase·다른 세션 소유면 거절 → `origin/<기준>` fetch(새 커밋이 없거나 이미 반영됐으면 거절) → 기준이 움직였으면 rebase(finish와 같은 규칙) → `.claude/wt-verify.sh`(트리가 `wt verify` 기록과 같으면 건너뜀) → 레인 브랜치 push(finish와 같은 규칙) → 표식을 만들거나 새로 올린다(`state=ready`, 이전 상태는 덮음). 머지는 기다리지 않고 끝난다. `wt ready --cancel`은 표식을 지운다 — 표식의 레인 커밋이 이 레인 것(HEAD와 같거나 그 조상, 또는 이 브랜치가 한때 가리킨 커밋)일 때만이고, 같은 이름으로 다른 기계가 올린 표식·머지됨 표식은 남긴다(커밋 없는 `wt finish`도 같다). origin이 있어야 한다(혼자 쓰는 저장소는 `wt finish`·`wt train`).

`wt flush` (저장소 안 어디서나):
1. origin의 그 기준(`--base`, 기본 기본 브랜치) 표식을 읽는다. `state=ready`가 없으면 "준비된 레인이 없습니다"로 0.
2. GitHub 원격 + `gh`면 저장소가 rebase 머지를 허용하는지(`gh repo view --json rebaseMergeAllowed`) 먼저 보고, 허용하지 않으면 줄 서지 않고 실패한다(표식은 그대로). 그다음 머지 번호표(kind `train`, 메모 `flush`, `--priority`)를 받아 차례를 기다린다. 아니면 이 기계의 머지 잠금.
3. 차례를 받으면 `origin/<기준>`과 표식을 **다시** 읽고, 임시 통합 워크트리(`<저장소>.wt/.train-<pid>`)에 `state=ready`이고 오래되지 않은 레인을 표식을 만든 순서대로 `git merge --squash` → 커밋 하나씩 쌓는다(메시지는 finish의 squash 메시지). 충돌하는 레인은 빼고 계속, 이미 기준에 있는 레인은 표식만 머지됨으로 바꾼다.
4. `.worktreeinclude`·`.claude/wt-setup.sh`를 적용하고 `.claude/wt-verify.sh`를 **한 번** 돈다. 쌓은 트리가 누군가 검증한 트리(표식의 `tree`)와 같으면(레인 하나가 이미 최신 기준 위에 있었음) 건너뛴다(`WT_FORCE_VERIFY=1`이면 늘 돈다). 실패하면 **아무것도 머지하지 않고** 쌓은 레인 표식을 `state=failed against=<기준 sha>`로 바꾼 뒤 종료 코드 1. 범인 레인을 찾는 이분 탐색은 하지 않는다 — 각 주인이 `wt finish`로 혼자 검증·머지하면 깨는 레인만 거기서 멈춘다.
5. 검증이 끝나면 쌓은 레인의 표식을 다시 읽는다. 그사이 주인이 거뒀거나(`wt ready --cancel`, 실패·시간 초과로 끝난 `wt finish`) 새 커밋으로 다시 올린 레인이 있으면 처음 읽은 커밋을 머지하지 않고 3부터 다시 쌓는다(거둔 레인은 빠지고 다시 올린 레인은 새 커밋으로, 이미 통과한 트리는 다시 검증하지 않음, 기준이 움직인 경우와 합쳐 5번까지). GitHub면 차례를 아직 쥐었는지·기준이 그대로인지 보고 `wt/batch-…` 브랜치 → PR → **rebase 머지**(`--match-head-commit`, 레인마다 커밋 하나) → `MERGED` 확인. 머지가 막히면(rebase 머지 꺼짐·보호 규칙·필수 체크) PR을 닫고 아무것도 머지하지 않는다(종료 코드 1, 표식은 그대로). 원격이 GitHub가 아니면 기준 브랜치로 push(그사이 움직였으면 거절된다). 기준이 움직였으면 다시 쌓아 검증한다(5번까지).
6. 머지한 레인의 표식은 지우지 않고 `state=merged against=<머지 뒤 기준 sha>`로 바꾼다(그 sha일 때만 — 주인이 그사이 새 커밋으로 다시 올렸으면 그대로). 원격 레인 브랜치는 머지한 커밋 그대로일 때만 지운다. 뺀 레인 표식은 `state=conflict against=<기준 sha>`로 바꾼다. 메인 폴더를 fast-forward.
7. **다른 기계의 워크트리는 건드리지 않는다**(이 기계 것도). 머지된 레인은 그 기계의 `wt finish`("이미 반영된 레인입니다" → 정리만)·`wt list`(`[<기준>에 반영됨]`)·`wt gc`가 치운다. 내용 비교(squash 포함)에 더해 머지됨 표식으로도 판정한다 — 레인이 그때 머지한 레인 커밋과 같거나 그 조상이고 그때 기준이 지금 기준에 들어 있으면 반영된 것(그 뒤 커밋이 더 있으면 아님). 그래서 커밋 여럿인 레인이 머지된 뒤 다른 레인이 같은 줄을 또 바꿔도 rebase 충돌 없이 정리된다. 머지됨 표식은 주인의 `wt finish`·`wt gc --apply`가 정리할 때 지운다. `WT_NO_READY=1`(원격을 읽지 않는 list)은 내용 비교만 한다.
8. 종료 코드: 0 머지(또는 준비된 레인 없음 — 동시에 돈 다른 flush가 먼저 머지했을 때도), 3 충돌로 뺀 레인이 있음(나머지는 머지됨) 또는 차례 대기 시간 초과, 1 실패.

**자동 묶음**(GitHub 대기열의 `wt finish`, 기본 켬 — `git config wt.autobatch false`로 끔):
1. rebase·검증까지는 지금과 같다. 그다음 줄에 서기 **전에** 레인 브랜치를 push하고 검증한 커밋으로 준비됨 표식을 올린다. 저장소가 rebase 머지를 허용하지 않으면(`gh repo view`) 표식을 올리지 않고 이 레인만 squash 머지한다(헛 묶음 검증을 돌지 않게).
2. 차례를 기다리는 동안 대기열을 볼 때마다 표식을 본다. 표식이 머지됨(위 7의 판정)이거나, 사라졌고(옛 판 wt) 레인 내용이 `origin/<기준>`에 들어 있으면 앞 차례가 함께 머지한 것이다 → 번호표를 지우고 정리만 하고 **종료 코드 0**. 표식이 `conflict`·`failed`로 바뀌었으면 알리고 계속 기다린다(내 차례에 직접 올려 검증한다).
3. 차례를 받으면 기준을 다시 받아 이미 들어 있으면 정리만. 아니면 다른 `state=ready` 레인이 있을 때 **내 레인을 맨 앞에** 두고 flush 3~6처럼 묶어 검증 한 번으로 머지한다. 묶을 레인이 없거나, 내 레인이 새 기준과 충돌하거나, 묶음 검증이 실패하거나(함께 쌓은 다른 표식은 `failed`), 묶음 PR 머지가 막히면(rebase 머지 꺼짐 등) 지금처럼 이 레인만 rebase·검증·squash 머지한다.
4. 내 레인이 머지되면 함께 쌓은 다른 레인이 충돌로 빠졌어도 종료 코드 0(빠진 레인은 표식과 안내로 남는다). 어떻게 끝나든(성공·실패·Ctrl-C·시간 초과) 이 레인의 표식을 지운다(머지됨 표식은 남긴다) — 고치는 사이 다른 곳이 옛 내용을 머지하지 않게. 다른 곳이 쌓아 검증 중이었다면 그쪽이 검증 뒤 표식을 다시 읽어 이 레인을 뺀다(검증이 끝난 뒤 머지 직전 몇 초 사이에 지우면 막지 못한다 — 다음 `wt finish`가 "이미 반영됨"으로 정리한다). 묶음에 올린 뒤 기다리는 사이 레인에 새 커밋·변경이 생겼으면 검증한 커밋까지만 머지하고 워크트리를 남긴 채 1로 끝난다(다시 `wt finish`).
5. `--priority critical`은 묶음을 기다리지도, 다른 레인을 묶지도 않는다(표식을 올리지 않는다). GitHub가 아니면(머지 잠금 경로) 자동 묶음은 없다 — `wt ready` + `wt flush`를 쓴다.

**언제 무엇을**:

| 상황 | 쓰는 것 |
|---|---|
| 급하지 않은 수정, 다른 레인과 함께 들어가도 됨 | `wt ready` → 나중에(누구든) `wt flush` |
| 공개 직전, 쌓인 준비됨 레인을 모두 넣고 싶다 | `wt flush` → 공개 |
| 지금 머지해야 함(보통) | `wt finish` — 줄 서는 동안 자동 묶음이 검증 횟수를 줄인다 |
| 급한 수정(장애·막힘) | `wt finish --priority critical` — 묶지 않고 앞쪽 등급 |
| 한 기계에서 함께 끝난 레인 여럿(origin 표식 없이) | `wt train <레인>...` |

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
- **살아 있음**: 번호표의 pid(finish·train은 wt 자신, `wt queue enter`는 `--pid`)가 살아 있는 동안 백그라운드 갱신이 번호표를 받자마자 한 번, 그 뒤 1분(`WT_QUEUE_BEAT`)마다 번호표를 새 커밋 시각으로 다시 올린다. 갱신 커밋의 제목에는 `note=` 앞에 표식 `beat=1`이 붙는다(옛 판 wt도 필드를 이름으로 읽어 그대로 읽는다). `wt queue enter`가 차례를 받고 끝나도 갱신은 남아 `--pid`를 지켜본다. 그 pid가 끝나면 갱신이 번호표와 그 차례(`_head`)를 지운다(강제 종료돼도 다음 주기에 풀린다). push가 실패하면 origin을 다시 보고, 아직 자기 번호표면 다음 주기에 다시 시도하고, 없어졌거나 바뀌었으면(`wt queue leave`·넘겨받힘) 끝난다.
- **놓기 실패**: 번호표를 놓을 때(머지 끝·시간 초과·실패·Ctrl-C·`wt queue leave`·`--pid` 끝남) origin에서 지우지 못하면(네트워크가 잠깐 끊김) 갱신을 멈추고 백그라운드가 `WT_QUEUE_POLL`(5)초마다 최대 30분(`WT_QUEUE_REAP`, 낡음 판정과 같음) 다시 지운다. 놓기(머지 끝·시간 초과·실패·Ctrl-C·`wt queue leave`)는 이름으로 지우고, `--pid` 끝남과 번호표 push 결과를 모를 때는 갱신·push가 알던 sha(올라갔는지 모르는 갱신 sha 포함)일 때만 지운다. 이미 지워졌으면 조용히 끝나고(sha로 지울 때는 늦게 반영되는 push를 대비해 처음 빈 결과를 본 뒤 `WT_QUEUE_LATE`(30)초 동안 더 본다 — 그보다 늦게 반영된 번호표는 한 번도 갱신되지 않았으므로 낡음 판정이 host와 관계없이 약 5분 뒤 치운다), 남의 차례(`_head`)는 건드리지 않는다. `wt queue enter`는 번호표 push가 실패로 보이면 서버에 들어갔을 때를 대비해 같은 정리를 띄우고 1로 끝나며, `wt queue leave`도 실패하면 1로 끝난다. 정리 프로세스는 git 공용 폴더에서 돌아(갱신도 같음) 워크트리가 지워져도 동작하고, 부른 쪽의 git 위치 환경(`GIT_DIR` 등, 상대 경로일 수 있음)과 0~2 밖의 열린 fd는 물려받지 않는다.
- **낡은 번호표**: 마지막 갱신이 30분보다 오래됐거나(kind와 관계없이), 갱신 표식(`beat=1`)이 없고 만든 지 갱신 주기의 3배 + 시계 여유 `WT_QUEUE_SKEW`(120초)보다 오래됐거나(host와 관계없이, 기본 5분 — 표식이 없으면 갱신이 한 번도 올라가지 않은 것: 결과를 모른 채 늦게 반영된 번호표 push의 고아이거나 번호표를 만든 뒤 몇 초 안에 끊긴 기계. 그런 번호표가 다른 기계를 30분 막지 않게. 다만 옛 판 wt는 표식 없이 갱신하므로 표식이 없어도 커밋 시각이 번호의 생성 시각에서 갱신 주기 절반 넘게 지났으면 갱신된 것으로 본다 — 둘 다 만든 기계의 시계라 시계 차이와 무관하지만 모든 기계의 `WT_QUEUE_BEAT`가 같아야 한다), 같은 host에서 그 pid가 끝났고 마지막 갱신이 갱신 주기의 3배보다 오래됐으면 경고 한 줄(`경고: 낡은 번호표를 지웁니다(<기준>/<번호>): …`) 뒤 그 sha에 lease를 건 삭제. 30분 규칙은 한 번이라도 갱신된 번호표(네트워크가 잠깐 끊긴 기계의 차례를 성급히 빼앗지 않게)에만 남는다. 갱신이 신선한 번호표는 pid로 지우지 않는다(host 이름이 같은 다른 기계를 잘못 지우지 않게). 차례를 쥔 번호표도 같다. `_head`가 가리키는 번호표가 없어지면 `_head`도 지운다(차례가 풀린다).
- **갱신 상한**: 오래 사는 pid를 넘겨도 대기열이 무기한 막히지 않게, 번호표를 받은 때부터 `--wait` + `--max-hold`(기본 10800초 = 3시간, finish·train도 같음)가 지나면 갱신을 멈춘다. 받자마자 올린 첫 갱신은 상한 안에서 이미 올라갔으므로 그 뒤 30분이면 낡음으로 풀린다(첫 갱신마저 못 올렸으면 5분). `wt queue`는 1시간 넘게 쥔 차례를 `[차례 N분째 쥠 — 오래 쥔 차례]`, 갱신이 멈춘 번호표를 `[갱신 멈춤 N분]`으로 보여 준다.
- **시계**: 번호와 나이가 시각이므로 기계 시계(NTP)가 맞아야 한다.
- **옛 판 호환**(다음 판에서 제거): 대기열 이전 판의 finish·train은 `refs/wt-claims/merge-<기준>` 선점으로 머지한다. 차례를 받은 직후 그 선점이 살아 있으면(15분 안, 같은 host면 pid도 살아 있음) 최대 20분 기다린 뒤 기준을 다시 받는다 — 그사이 옛 판이 머지했으면 finish는 다시 rebase·검증하고, train은 머지하지 않고 멈춘다.
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

- `--pid $$`(필수): 스크립트가 살아 있는 동안 번호표가 갱신되므로 공개가 오래 걸려도 넘겨받히지 않는다. 스크립트가 끝나면(강제 종료 포함) 갱신이 1분 안에 번호표를 지운다. 기본값을 두지 않는 까닭: `$(wt queue enter …)`의 부모는 곧 끝나는 서브셸이다.
- **enter부터 leave까지는 한 스크립트(한 프로세스) 안에서** 한다. 에이전트 도구에서 `wt queue enter … --pid $$`만 한 번 부르고 공개를 다음 호출에서 하면, 첫 셸이 끝나는 순간 1분 안에 번호표가 지워져 차례 없이 공개하게 된다.
- 에이전트(Claude 등)가 finish·train·enter를 부를 때는 기본 대기 60분이 도구 한 번의 실행 상한(보통 10분)을 넘을 수 있으니 백그라운드로 돌리고 끝을 기다린다.
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

### `.claude/wt-teardown.sh` — 워크트리를 지우기 직전에 그 안에서 실행 (예시: `examples/wt-teardown.sh`)

- `wt finish`·`wt train`(레인과 통합 워크트리)·`wt gc --apply`가 워크트리를 지우기 바로 전에 부른다. 현재 폴더 = 지울 워크트리, 환경 변수 `WT_MAIN` = 메인 폴더(`wt-setup.sh`와 같다). 표준 입력은 닫혀 있다.
- 지울 워크트리에 스크립트가 없으면(스크립트를 커밋하기 전에 만든 레인) 메인 폴더의 것을 쓴다.
- 실패해도 정리는 막지 않고 경고만 낸다. 쓰임: `wt-setup.sh`가 워크트리 밖에 만든 것(경로별 색인·캐시, 띄운 서비스) 치우기.
- 하네스 `isolation: "worktree"`가 직접 지우는 워크트리, 손으로 지운 워크트리, 강제 종료로 끝난 train의 통합 워크트리에는 돌지 않는다. 남은 자원은 스크립트 쪽에서 "경로가 없는 것"을 지우는 식으로 따로 정리한다.

세 파일 모두 `chmod +x` 후 커밋한다. 없으면 그 단계는 건너뛴다. 저장소에 `.gitattributes`가 있으면 `*.sh text eol=lf`를 두어 줄바꿈 문제를 막는다.

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
| finish가 "머지 순번 k/n · 앞: …" | 다른 기계·세션이 머지·공개 중이다. 기다린다. 오래 멈춰 있으면 `wt queue`로 앞 번호표를 보고, 그 작업이 끝난 게 확실하면 `wt queue leave <번호표 ref>`(아니면 주인 프로세스가 끝난 번호표는 1분, 갱신이 멈춘 번호표는 30분 뒤 저절로 풀린다) |
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
| git **2.38 이상** (최소 2.31) | squash 반영 판정·줄 단위 충돌 예고가 `git merge-tree --write-tree`를 쓴다(미만이면 충돌 예고는 파일 단위). 2.31 미만은 지원하지 않는다: git 위치 환경 처리(4절)가 `rev-parse --path-format=absolute`를 쓴다 |
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
