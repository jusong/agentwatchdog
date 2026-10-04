# AgentWatchdog 🐕

Claude Code 看门狗 MVP —— 监控本地 agent 花费，超预算自动熔断。

menubar 常驻：今日烧钱 / 7 天烧钱 / Top 会话 / 在跑 agent 巡检 / 预算熔断（通知 + AGENT_STOP + hook 阻断）。

## 快速开始

```bash
./build.sh        # 编译 + 自检 + 打包 + 启动
```

看屏幕顶部菜单栏的 **🐕 $x.xx**，点击展开面板。

**30 秒演示熔断**：面板里点 **⚡ Simulate rogue (+$47)**（默认预算 $20）→ 数字变红 🔴 → macOS 弹通知 → `~/.claude/AGENT_STOP` 写入 → （若已注册 hook）Claude Code 的所有工具调用被拒。点 **Reset & rearm** 恢复。

## 启用真实熔断

**本机已注册**（v1.1 安装时写入，备份在 `~/.claude/settings.json.bak-watchdog`）。手动注册/其他机器：把下面加进 `~/.claude/settings.json` 的 `hooks`：

```json
{
  "hooks": {
    "PreToolUse":  [ { "matcher": "*", "hooks": [ { "type": "command",
        "command": "python3 \"$HOME/Documents/deepseek-harness/default-workspace/watchdog/watchdog-guard.py\"", "timeout": 10 } ] } ],
    "PostToolUse": [ { "matcher": "*", "hooks": [ { "type": "command",
        "command": "python3 \"$HOME/Documents/deepseek-harness/default-workspace/watchdog/watchdog-guard.py\"", "timeout": 10 } ] } ]
  }
}
```

熔断状态通过 `~/.watchdog/state.json` 传递（app 每 15s 刷新，guard 每次工具调用读改写），无守护进程。**fail-open**：guard 自身出错时放行，看门狗不能变成故障点。

**三条熔断规则**（阈值可在 `~/.watchdog/config.json` 覆盖）：

| 规则 | 默认 | 行为 |
|---|---|---|
| 预算 | 今日烧钱 ≥ 日预算 | deny + 通知 + AGENT_STOP |
| 循环 | 同 session 同 tool 同参数 ≥8 次/10 分钟 | deny + trip |
| 连续报错 | 同 session 连续 ≥5 次工具失败 | trip（下次调用起 deny） |

## 自检

```bash
./selfcheck.sh    # 6 项：CLI 计量 / demo 解析 / hook 预算 deny·allow / guard 循环 / guard 连续报错
./build/Watchdog --stats ~/.claude/projects   # 只看数字 + hook 注册状态
```

## 文件

| 文件 | 作用 |
|---|---|
| `Watchdog.swift` | menubar app（~330 行）：JSONL 扫描/计价/预算/巡检/通知/UI |
| `watchdog-guard.py` | Pre/PostToolUse hook：预算 + 循环检测 + 连续报错三条熔断规则 |
| `watchdog-hook.sh` | 旧版纯预算 hook（保留作兼容/最小依赖示例） |
| `build.sh` / `selfcheck.sh` | 一键构建 + 6 项最小检查（不依赖 GUI） |
| `site/index.html` | 落地页（恐惧叙事 + 规则说明 + 定价 + FAQ，两个 TODO 待填） |
| `site/launch-kit.md` | Show HN/Reddit/PH/X 发布文案包 + 发布前清单 + 止损线 |
| `demo/` | rogue 场景假数据（≈$199/日），供 selftest 与演示 |

## MVP 边界（刻意不做，见 agent-watchdog-go-plan.md）

- 只读本地 `~/.claude/projects`（订阅制 Claude Code），**估算值 ≠ 账单**：token × 硬编码价目表（Sonnet $3/$15、Opus $15/$75、Haiku $0.8/$4 / 1M tokens，缓存读 0.1×、写 1.25×——调价改 `priceTable`）
- 无 Cursor 熔断（云端无 hook，v1.x 仅通知）、无多机、无云
- 已知局限（`ponytail:`）：15s 全量重扫（万级 jsonl 需增量）；循环检测按参数哈希（语义等价的不同参数不合并）；阈值 8/10min、5 次为初始值，跑一周按误报率调

## 卸载

```bash
pkill -f AgentWatchdog && rm -rf build ~/.watchdog ~/.claude/AGENT_STOP
```
