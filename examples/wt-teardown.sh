#!/usr/bin/env bash
# 저장소의 .claude/wt-teardown.sh 로 복사해 쓴다. wt finish·train·gc --apply가 워크트리를 지우기 직전에
# 그 워크트리 안에서 실행한다. WT_MAIN = 메인 폴더 경로. 실패해도 워크트리 정리는 계속된다(경고만).
# 쓰임: wt-setup.sh가 워크트리 밖에 만든 것(경로별 색인·캐시, 띄운 서비스)을 치운다.
set -euo pipefail
# 예: setup이 경로별 캐시를 만들었다면
# rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/my-tool/$(printf '%s' "$PWD" | tr / -)"
exit 0
