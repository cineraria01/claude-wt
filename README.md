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
| 도구 | `~/.claude/bin/wt` (PATH의 `wt`) | start / finish / verify / list / gc / overlap / claim |
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
| `wt finish [--title "..."]` | 워크트리 안 | 5절 순서로 머지·정리 |
| `wt verify` | 워크트리 안 | `.claude/wt-verify.sh` 실행. 통과하면 그 코드의 트리 해시를 기록하고, rebase 뒤에도 트리가 같으면 finish가 검증을 건너뛴다. 미커밋 변경이 있으면 거절 |
| `wt list [--conflicts]` | 저장소 안 어디서나 | 워크트리·브랜치 상태(레인마다 **자기 기준** 대비 앞선 커밋 수, `[기준 v2]`, `[<기준>에 반영됨]`, `[기준 브랜치]`, 미커밋 변경, 소유자). `--conflicts`는 레인별 예상 충돌 |
| `wt gc [--apply]` | 저장소 안 어디서나 | 자기 기준에 이미 반영된 워크트리·브랜치 정리. 기준 브랜치는 지우지 않는다(12절). 기본은 목록만 |
| `wt overlap` | 워크트리 안 | 같은 기준의 다른 레인·기준 브랜치와 **미리 합쳐 보고**(`git merge-tree`, 작업 폴더는 그대로) 실제로 충돌할 파일은 `충돌 예상`, 같은 파일이지만 줄이 안 겹치면 `겹침(자동 병합 가능)`. 다른 레인의 미커밋 변경도 포함. git 2.38 미만이면 파일 단위 겹침 |
| `wt claim [--force]` | 워크트리 안 | 재개·압축·인계 뒤 이 세션이 그 워크트리를 맡는다 |

## 5. `wt finish` 순서

1. 미커밋 변경·진행 중 rebase가 있으면 중단. 다른 살아 있는 세션 소유면 중단(`wt claim --force` 또는 `WT_FORCE_FINISH=1` 필요).
2. 충돌 예고를 한 줄로 요약한다(다른 레인과 충돌 예상, 기준과 충돌 예상, 자동 병합 가능 겹침 개수. 자세히는 `wt overlap`).
3. 잠금 `<git-common-dir>/wt-finish.lock`을 잡는다. 동시에 끝나는 레인은 차례로 머지된다(최대 10분 대기).
4. `origin/<base>`를 fetch하고(base = 그 레인의 기준), 새 커밋이 없으면 정리만 한다.
5. `origin/<base>` 위로 rebase. 충돌이면 중단 → 그 워크트리에서 풀고 `git rebase --continue` → 검증 → finish 재실행.
   - 기준이 이미 들어 있으면 rebase하지 않는다. 레인 안에 합치기 커밋이 있으면(여러 레인을 합친 통합 레인) rebase 대신 기준을 merge로 받는다. rebase는 합치기를 한 줄로 다시 쌓아 이미 푼 충돌을 또 내기 때문이다. squash 머지라 결과는 같다. merge 충돌이면 풀고 `git commit` → 검증 → finish 재실행.
6. `.claude/wt-verify.sh`가 있으면 실행. 실패하면 머지하지 않는다. rebase 뒤 트리가 `wt verify`(또는 앞선 finish)가 통과시킨 트리와 같으면 건너뛴다(`WT_FORCE_VERIFY=1`이면 늘 실행).
7. GitHub 원격 + `gh`가 있으면: push(`--force-with-lease`) → PR 생성(없을 때) → **squash 머지** → 상태가 `MERGED`인지 확인 → 원격 브랜치 삭제.
   원격이 없거나 GitHub가 아니면: 로컬에서 squash 커밋 → (원격 있으면) push → 기본 브랜치 fast-forward.
8. 하네스가 건 `claude agent …` 잠금만 풀고 워크트리·로컬 브랜치 삭제.
9. 메인 폴더가 그 기준 브랜치에 있으면 `origin/<base>`로 fast-forward.

squash 커밋 메시지: 커밋이 1개면 그 메시지 그대로, 여러 개면 `--title`(없으면 첫 커밋 제목) + 각 커밋 요약 + 중복을 뺀 `Co-Authored-By`.

## 6. 세션 소유 표식

- `wt start`·`wt claim`이 `<워크트리 git-dir>/wt-owner`에 `세션ID pid 시각`을 쓴다. pid는 명령을 부른 `claude` 프로세스.
- 판정: 내 세션 ID면 `[이 세션]`, pid가 살아 있는 다른 `claude`면 `[다른 세션 사용 중]`, 죽었으면 `[주인 세션 종료됨]`.
- 서브에이전트 워크트리는 하네스가 `claude agent … (pid N …)` 사유로 git 잠금을 건다. N이 살아 있는 다른 세션이면 `[다른 세션 에이전트 실행 중]`.
- `[다른 세션 사용 중]` 워크트리는 건드리지 않는다(`finish`·`gc`도 막는다). `[주인 세션 종료됨]`이나 표식 없는 것은 내가 만든 게 아니면 사용자에게 묻는다.

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
| finish가 "다른 finish가 진행 중" | 기다린다. 10분 넘게 멈춘 잠금이면 `rmdir <git-common-dir>/wt-finish.lock` |
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
