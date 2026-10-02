#!/usr/bin/env bash
# claude-wt 제거: wt·훅 파일을 지우고 settings.json에서 wt 훅 등록을 뺀다.
# ~/.claude/CLAUDE.md의 "작업 격리" 절과 셸 rc의 PATH 줄은 직접 지운다.
set -euo pipefail
C="$HOME/.claude"
rm -f "$C/bin/wt" "$C/hooks/wt-main-guard" "$C/hooks/wt-remove-guard" "$C/hooks/wt-session-status"
[ -f "$C/settings.json" ] || exit 0
cp "$C/settings.json" "$C/settings.json.bak-$(date +%Y%m%d%H%M%S)"
python3 - "$C/settings.json" <<'PY_EOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); hooks = d.get("hooks", {})
names = ("wt-main-guard", "wt-remove-guard", "wt-session-status")
for ev in list(hooks):
    keep = []
    for m in hooks[ev]:
        m["hooks"] = [h for h in m.get("hooks", []) if not any(n in h.get("command", "") for n in names)]
        if m["hooks"]: keep.append(m)
    if keep: hooks[ev] = keep
    else: del hooks[ev]
json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
print("settings.json에서 wt 훅 제거:", p)
PY_EOF
echo '제거 완료. ~/.claude/CLAUDE.md의 "# 작업 격리" 절과 셸 rc의 .claude/bin PATH 줄은 직접 지우세요.'
