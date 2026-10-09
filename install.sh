#!/usr/bin/env bash
# claude-wt 설치: Claude Code 워크트리 작업 격리(wt 도구 + 훅 3개 + 규칙 절)
#
#   curl -fsSL https://raw.githubusercontent.com/cineraria01/claude-wt/main/install.sh | bash
#   또는 clone 후: bash install.sh
#
# 여러 번 실행해도 된다(갱신). 기존 wt·훅·settings.json은 .bak-<시각>으로 남긴다.
# CLAUDE_WT_REF=<브랜치·태그>로 받을 버전을 고를 수 있다(기본 main).
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/cineraria01/claude-wt/${CLAUDE_WT_REF:-main}"
FILES="bin/wt hooks/wt-main-guard hooks/wt-remove-guard hooks/wt-session-status rules/worktree-isolation.md"
CLAUDE_DIR="$HOME/.claude"
ts=$(date +%Y%m%d%H%M%S)

command -v git >/dev/null || { echo "claude-wt: git이 필요합니다" >&2; exit 1; }
command -v python3 >/dev/null || { echo "claude-wt: python3가 필요합니다" >&2; exit 1; }

# clone한 폴더에서 실행하면 그 파일을, 파이프로 실행하면 GitHub에서 받는다.
src=""
here=$(cd "$(dirname "${BASH_SOURCE[0]:-/dev/null}")" 2>/dev/null && pwd || true)
if [ -n "$here" ] && [ -f "$here/bin/wt" ] && [ -f "$here/rules/worktree-isolation.md" ]; then
  src=$here
else
  command -v curl >/dev/null || { echo "claude-wt: curl이 필요합니다" >&2; exit 1; }
  src=$(mktemp -d)
  trap 'rm -rf "$src"' EXIT
  for f in $FILES; do
    mkdir -p "$src/$(dirname "$f")"
    curl -fsSL "$REPO_RAW/$f" -o "$src/$f" || { echo "claude-wt: 받기 실패 $REPO_RAW/$f" >&2; exit 1; }
  done
fi

# 1) 도구·훅
mkdir -p "$CLAUDE_DIR/bin" "$CLAUDE_DIR/hooks"
for f in bin/wt hooks/wt-main-guard hooks/wt-remove-guard hooks/wt-session-status; do
  dst="$CLAUDE_DIR/$f"
  [ -f "$dst" ] && ! cmp -s "$src/$f" "$dst" && cp "$dst" "$dst.bak-$ts"
  # 실행 중인 wt가 읽던 파일을 제자리에서 덮지 않게 새 파일로 바꿔 끼운다.
  cp "$src/$f" "$dst.new.$$" && chmod +x "$dst.new.$$" && mv -f "$dst.new.$$" "$dst"
done
echo "설치: ~/.claude/bin/wt, ~/.claude/hooks/wt-{main-guard,remove-guard,session-status}"

# 훅은 /usr/bin/python3를 직접 부른다.
[ -x /usr/bin/python3 ] || echo "경고: /usr/bin/python3가 없습니다. ~/.claude/hooks/wt-* 안의 /usr/bin/python3를 $(command -v python3) 로 바꾸세요" >&2

# 2) settings.json 훅 등록(기존 설정 유지, 중복 등록 안 함)
[ -f "$CLAUDE_DIR/settings.json" ] && cp "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.json.bak-$ts"
python3 - "$CLAUDE_DIR/settings.json" <<'PY_EOF'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) else {}
hooks = d.setdefault("hooks", {})
def add(event, matcher, name):
    cmd = '"$HOME/.claude/hooks/%s"' % name
    arr = hooks.setdefault(event, [])
    for m in arr:
        if m.get("matcher") == matcher and any(h.get("command") == cmd for h in m.get("hooks", [])):
            return
    arr.append({"matcher": matcher, "hooks": [{"type": "command", "command": cmd, "timeout": 5}]})
for m in ("startup", "resume", "clear", "compact"):
    add("SessionStart", m, "wt-session-status")
add("PreToolUse", "Edit|Write|MultiEdit|NotebookEdit", "wt-main-guard")
add("PreToolUse", "Bash", "wt-remove-guard")
json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
print("settings.json 훅 등록:", p)
PY_EOF

# 3) 전역 CLAUDE.md에 규칙 절(이미 있으면 건너뜀)
touch "$CLAUDE_DIR/CLAUDE.md"
if grep -q '^# 작업 격리' "$CLAUDE_DIR/CLAUDE.md"; then
  echo "CLAUDE.md: '작업 격리' 절이 이미 있어 건너뜀(새 내용은 rules/worktree-isolation.md)"
else
  { [ -s "$CLAUDE_DIR/CLAUDE.md" ] && printf '\n'; cat "$src/rules/worktree-isolation.md"; } >> "$CLAUDE_DIR/CLAUDE.md"
  echo "CLAUDE.md: '작업 격리' 절 추가"
fi

# 4) PATH
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  [ -f "$rc" ] || continue
  grep -q '.claude/bin' "$rc" || printf '\nexport PATH="$HOME/.claude/bin:$PATH"\n' >> "$rc"
done

echo '완료. 새 셸을 열거나 export PATH="$HOME/.claude/bin:$PATH" 실행 후 wt 로 확인하고, Claude Code를 재시작하세요.'
