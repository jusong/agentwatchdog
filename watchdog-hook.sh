#!/bin/bash
# AgentWatchdog — Claude Code PreToolUse hook
# 读取 ~/.watchdog/state.json，超预算/已熔断时拒绝所有工具调用（软熔断：预算内自动恢复，硬熔断需在 menubar Reset）
set -u
STATE="${WATCHDOG_STATE:-$HOME/.watchdog/state.json}"
[ -f "$STATE" ] && [ -x "$(command -v python3)" ] || exit 0

eval "$(python3 - "$STATE" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(f'BURN={d["today_burn"]:.4f}')
    print(f'BUDGET={d["budget"]:.2f}')
    print(f'TRIPPED={"1" if d.get("tripped") else "0"}')
except Exception:
    print('BURN=0'); print('BUDGET=999999'); print('TRIPPED=0')
PY
)"

OVER=$(awk -v b="$BURN" -v u="$BUDGET" 'BEGIN{print (b>=u)?1:0}')
if [ "$TRIPPED" = "1" ] || [ "$OVER" = "1" ]; then
  REASON="AgentWatchdog: daily budget \$${BUDGET} exceeded (burn \$${BURN}). Raise the budget in the menubar app or click 'Reset & rearm'."
  cat <<EOF
{"decision":"block","reason":"$REASON","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"$REASON"}}
EOF
fi
exit 0
