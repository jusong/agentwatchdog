#!/bin/bash
# AgentWatchdog build — 编译、打包 .app、生成 demo 数据、selftest、启动
set -euo pipefail
cd "$(dirname "$0")"

echo "[1/6] 生成 demo 数据（rogue 场景 ≈USD190/日）..."
rm -rf demo
python3 - <<'PY'
import json, datetime, os
out = "demo/-Users-demo-rogue-app/rogue-session.jsonl"
os.makedirs(os.path.dirname(out), exist_ok=True)
now = datetime.datetime.now(datetime.timezone.utc)
def ts(k):
    t = now - datetime.timedelta(minutes=3*k)
    return t.strftime('%Y-%m-%dT%H:%M:') + f"{t.second:02d}.{t.microsecond//1000:03d}Z"
lines = []
# 40 条 opus（每条 ≈$4.1）+ 20 条 sonnet（每条 ≈$1.7）≈ $199
for k in range(40):
    lines.append(json.dumps({
        "type": "assistant",
        "timestamp": ts(k),
        "sessionId": "rogue-001",
        "message": {"id": f"demo-opus-{k}", "model": "claude-opus-4-6-20260219",
                    "usage": {"input_tokens": 20000, "output_tokens": 45000,
                              "cache_read_input_tokens": 60000, "cache_creation_input_tokens": 20000}}}))
for k in range(20):
    lines.append(json.dumps({
        "type": "assistant",
        "timestamp": ts(k),
        "sessionId": "rogue-002",
        "message": {"id": f"demo-sonnet-{k}", "model": "claude-sonnet-4-5-20250929",
                    "usage": {"input_tokens": 60000, "output_tokens": 80000,
                              "cache_read_input_tokens": 80000, "cache_creation_input_tokens": 40000}}}))
open(out, "w").write("\n".join(lines) + "\n")
print(f"demo jsonl: {len(lines)} lines")
PY

echo "[2/6] 编译 Watchdog.swift..."
mkdir -p build build/tmp build/ModuleCache
TMPDIR="$PWD/build/tmp" swiftc -swift-version 5 -module-cache-path "$PWD/build/ModuleCache" -parse-as-library -O -o build/Watchdog Watchdog.swift

echo "[3/6] selftest（计价公式 + demo 解析）..."
WATCHDOG_DATA_DIR="$PWD/demo" ./build/Watchdog --selftest

echo "[4/6] 打包 AgentWatchdog.app..."
APP="build/AgentWatchdog.app/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources"
cp build/Watchdog "$APP/MacOS/AgentWatchdog"
cp -R demo "$APP/Resources/demo"
chmod +x watchdog-hook.sh
cat > "build/AgentWatchdog.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIdentifier</key><string>dev.indie.agentwatchdog</string>
    <key>CFBundleExecutable</key><string>AgentWatchdog</string>
    <key>CFBundleName</key><string>AgentWatchdog</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
EOF

echo "[5/6] hook 集成提示..."
echo "  真实熔断需把 watchdog-hook.sh 注册到 ~/.claude/settings.json（见 README）"
echo "  当前 state: $(cat ~/.watchdog/state.json 2>/dev/null || echo '尚未生成（启动 app 后 15s 内出现）')"

echo "[6/6] 启动 menubar app..."
open build/AgentWatchdog.app
echo "完成 ✓  看屏幕顶部菜单栏的 🐕 图标（点击展开面板）"
