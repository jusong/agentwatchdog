#!/bin/bash
# 最小可运行检查：CLI 计量 + hook 熔断行为（不依赖 GUI）
set -euo pipefail
cd "$(dirname "$0")"

echo "== 1. 计量与解析（真实数据 + demo 数据）=="
./build/Watchdog --stats "$HOME/.claude/projects" || true
WATCHDOG_DATA_DIR="$PWD/demo" ./build/Watchdog --selftest

echo "== 2. hook 熔断行为 =="
FAKE_HOME=$(mktemp -d)
mkdir -p "$FAKE_HOME/.watchdog"
echo '{"today_burn": 187.50, "budget": 20.00, "tripped": false}' > "$FAKE_HOME/.watchdog/state.json"
OUT=$(HOME="$FAKE_HOME" ./watchdog-hook.sh)
echo "$OUT" | grep -q '"permissionDecision":"deny"' && echo "PASS  over-budget -> deny ($OUT)"
[ ! -z "$OUT" ] || echo "FAIL: hook did not block"

echo '{"today_burn": 3.10, "budget": 20.00, "tripped": false}' > "$FAKE_HOME/.watchdog/state.json"
OUT2=$(HOME="$FAKE_HOME" ./watchdog-hook.sh)
[ -z "$OUT2" ] && echo "PASS  under-budget -> allow (empty output)"

echo "== 3. guard 规则（循环检测 / 连续报错）=="
GUARD="$PWD/watchdog-guard.py"
FAKE=$(mktemp -d)
mkdir -p "$FAKE/.watchdog"
echo '{"today_burn": 0.0, "budget": 9999.0, "tripped": false}' > "$FAKE/.watchdog/state.json"
call() { HOME="$FAKE" WATCHDOG_SILENT=1 python3 "$GUARD" <<< "$1"; }
# 前 3 次相同调用 + 1 次不同调用：都应放行
for i in 1 2 3; do [ -z "$(call '{"hook_event_name":"PreToolUse","session_id":"looptest","tool_name":"Bash","tool_input":{"command":"git status"}}')" ] || echo "FAIL: identical call $i should pass"; done
[ -z "$(call '{"hook_event_name":"PreToolUse","session_id":"looptest","tool_name":"Bash","tool_input":{"command":"different"}}')" ] && echo "PASS  varied call -> allow"
# 继续相同调用到第 8 次：应 deny（loop）
OUTL=""
for i in 4 5 6 7 8; do
  OUTL=$(call '{"hook_event_name":"PreToolUse","session_id":"looptest","tool_name":"Bash","tool_input":{"command":"git status"}}')
done
echo "$OUTL" | grep -q 'loop detected' && echo "PASS  loop rule -> deny on 8th identical call"
[ -z "$OUTL" ] && echo "FAIL: loop rule did not trigger"
# 连续报错 5 次 -> trip（先重置 state，避免被上一步的 loop trip 短路）
echo '{"today_burn": 0.0, "budget": 9999.0, "tripped": false}' > "$FAKE/.watchdog/state.json"
for i in 1 2 3 4 5; do
  call '{"hook_event_name":"PostToolUse","session_id":"errtest","tool_name":"Bash","tool_response":{"is_error":true}}' > /dev/null
done
python3 -c "import json;d=json.load(open('$FAKE/.watchdog/state.json'));exit(0 if d['tripped'] and 'error streak' in d['reason'] else 1)" \
  && echo "PASS  error streak -> trip" || echo "FAIL  error streak did not trip"
rm -rf "$FAKE" "$FAKE_HOME"
echo "== selfcheck done =="
