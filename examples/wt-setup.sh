#!/usr/bin/env bash
# 저장소의 .claude/wt-setup.sh 로 복사해 쓴다. wt start가 새 워크트리 안에서 실행한다.
# WT_MAIN = 메인 폴더 경로. 실패하면 start가 멈추고 워크트리는 남는다.
set -euo pipefail
# 예: Node 프로젝트
[ -f package-lock.json ] && npm ci
# 예: 메인 폴더의 gitignore된 빌드 산출물이 있어야 빌드되는 경우
# [ -d "$WT_MAIN/dist" ] && cp -R "$WT_MAIN/dist" dist
exit 0
