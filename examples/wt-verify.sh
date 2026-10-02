#!/usr/bin/env bash
# 저장소의 .claude/wt-verify.sh 로 복사해 쓴다. wt finish가 rebase 뒤, push 전에 실행한다.
# 0이 아닌 종료면 머지하지 않는다. 저장소의 전체 검증(포맷·빌드·테스트)을 넣는다.
set -euo pipefail
# 서브에이전트(isolation: "worktree") 워크트리는 wt-setup.sh를 거치지 않는다.
[ ! -f package.json ] || [ -d node_modules ] || npm ci
# 예:
# npm run lint
# npm test
