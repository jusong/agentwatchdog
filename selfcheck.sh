#!/bin/bash
# 最小可运行检查：计量解析 + 三条熔断规则的 hook 行为（不依赖 GUI）
#
# 注意：这里不用 `set -e`。测试脚本里 `test && echo PASS` 这种形态在 set -e 下不会中止，
# 结果就是无论过不过都退出 0 —— 一个永远不会失败的检查等于没有检查。
# 改成显式统计 + 显式 exit code。
set -uo pipefail
cd "$(dirname "$0")"

PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — 期望 [$3] 实际 [$2]"; fi; }

GUARD="$PWD/watchdog-guard.py"
BIN="build/Watchdog"

# 每个用例一个干净的 WATCHDOG_HOME，互不污染
newenv() { local d; d=$(mktemp -d); mkdir -p "$d/.watchdog"; echo "$d"; }
setstate(){ echo "{\"today_burn\": $2, \"budget\": $3, \"tripped\": false}" > "$1/.watchdog/state.json"; }
call()    { HOME="$1" WATCHDOG_SILENT=1 python3 "$GUARD" 2>/dev/null; }
tripped() { python3 -c "import json;print(json.load(open('$1/.watchdog/state.json'))['tripped'])" 2>/dev/null || echo "unreadable"; }
pre()     { echo "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"$2\",\"tool_name\":\"Bash\",\"tool_input\":$3}"; }
post()    { echo "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$1\",\"tool_response\":$2}"; }

echo "== 1. 计价公式与 demo 解析 =="
if [ ! -x "$BIN" ]; then
  echo "  … $BIN 不存在，先编译"
  mkdir -p build/tmp build/ModuleCache
  TMPDIR="$PWD/build/tmp" swiftc -swift-version 5 -module-cache-path "$PWD/build/ModuleCache" \
    -parse-as-library -O -o "$BIN" Watchdog.swift || { echo "  ✗ 编译失败"; exit 1; }
fi
# 夹具的时间戳是相对生成时刻的，放一天就过期——"目录存在"不代表"数据是今天的"。
# 所以每次都重新生成，别拿旧夹具算出 $0.00 来当通过。
python3 scripts/mkdemo.py demo >/dev/null
if "$BIN" --stats "$HOME/.claude/projects" 2>/dev/null; then ok "CLI 计量 (--stats 真实数据)"; else bad "CLI 计量"; fi
if WATCHDOG_DATA_DIR="$PWD/demo" "$BIN" --selftest; then ok "计价公式 + demo 解析"; else bad "计价公式 + demo 解析"; fi

echo "== 2. 预算熔断（guard 自身，不是旧版 .sh）=="
H=$(newenv); setstate "$H" 187.50 20.00
OUT=$(pre "$H" s1 '{"command":"ls"}' | call "$H")
echo "$OUT" | grep -q '"permissionDecision": "deny"' && ok "超预算 -> deny" || bad "超预算 -> deny（实际输出: ${OUT:0:80}）"
H=$(newenv); setstate "$H" 3.10 20.00
OUT=$(pre "$H" s1 '{"command":"ls"}' | call "$H")
[ -z "$OUT" ] && ok "未超预算 -> 放行" || bad "未超预算 -> 放行（输出了 $OUT）"

echo "== 3. 循环检测 =="
H=$(newenv); setstate "$H" 0 9999
for _ in $(seq 1 8); do pre "$H" s1 '{"command":"git status"}' | call "$H" >/dev/null; done
check "同参数 8 次 -> 熔断" "$(tripped "$H")" "True"
H=$(newenv); setstate "$H" 0 9999
for _ in $(seq 1 7); do pre "$H" s1 '{"command":"git status"}' | call "$H" >/dev/null; done
check "同参数 7 次 -> 不熔断" "$(tripped "$H")" "False"
H=$(newenv); setstate "$H" 0 9999
for _ in $(seq 1 8); do
  pre "$H" s1 "{\"command\":\"git status\",\"description\":\"第 $RANDOM 次尝试看看改动\"}" | call "$H" >/dev/null
done
check "Bash description 变化不影响判定（防换说法绕过）" "$(tripped "$H")" "True"
H=$(newenv); setstate "$H" 0 9999
for i in $(seq 1 8); do pre "$H" s1 "{\"command\":\"cmd-$i\"}" | call "$H" >/dev/null; done
check "参数各不相同 -> 不误杀" "$(tripped "$H")" "False"

echo "== 4. 连续报错（成功即清零）=="
H=$(newenv); setstate "$H" 0 9999
for _ in $(seq 1 5); do post s1 '{"is_error":true}' | call "$H" >/dev/null; done
check "真·连续 5 次失败 -> 熔断" "$(tripped "$H")" "True"
H=$(newenv); setstate "$H" 0 9999
for _ in 1 2 3; do post s1 '{"is_error":true}' | call "$H" >/dev/null; done
for _ in $(seq 1 20); do post s1 '{"ok":true}' | call "$H" >/dev/null; done
for _ in 4 5; do post s1 '{"is_error":true}' | call "$H" >/dev/null; done
check "3 失败 + 20 成功 + 2 失败 -> 不熔断" "$(tripped "$H")" "False"

echo "== 5. 健壮性：状态损坏 / 单行损坏 =="
H=$(newenv); setstate "$H" 187.50 20.00
cp "$H/.watchdog/state.json" "$H/.watchdog/state.json.bak"
printf '{"today_burn": 187.5, "bud' > "$H/.watchdog/state.json"   # 模拟写一半被 kill
OUT=$(pre "$H" s1 '{"command":"ls"}' | call "$H")
echo "$OUT" | grep -q 'budget' && ok "state 损坏 -> 退回备份并继续拦截" || bad "state 损坏后保护静默消失（fail-open 变静默失效）"
python3 -c "import json;json.load(open('$H/.watchdog/state.json'))" 2>/dev/null \
  && ok "损坏文件未被二次写坏" || bad "state 文件仍损坏"
H=$(newenv); setstate "$H" 0 9999
for _ in $(seq 1 7); do pre "$H" s1 '{"command":"x"}' | call "$H" >/dev/null; done
echo '{"ts":0,"BROKEN' >> "$H/.watchdog/events.jsonl"   # 末行截断
pre "$H" s1 '{"command":"x"}' | call "$H" >/dev/null
check "events.jsonl 一行损坏后循环检测仍生效" "$(tripped "$H")" "True"

echo "== 6. 逃生舱（无 GUI 也能复位）=="
H=$(newenv); setstate "$H" 0 9999
echo '{"today_burn":0.0,"budget":20.00,"tripped":true,"reason":"manual test"}' > "$H/.watchdog/state.json"
HOME="$H" WATCHDOG_SILENT=1 python3 "$GUARD" --reset >/dev/null 2>&1
check "--reset 清除熔断" "$(tripped "$H")" "False"

echo
echo "=============================="
echo "通过 $PASS · 失败 $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ] || exit 1
