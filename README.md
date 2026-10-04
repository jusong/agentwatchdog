# AgentWatchdog 🐕

Claude Code 看门狗 MVP —— 监控本地 agent 花费，超预算自动熔断。

menubar 常驻：今日烧钱 / 7 天烧钱 / Top 会话 / 在跑 agent 巡检 / 预算熔断（通知 + AGENT_STOP + hook 阻断）。

## 快速开始

```bash
./build.sh        # 编译 + 自检 + 打包 + 启动
```

看屏幕顶部菜单栏的 **🐕 $x.xx**，点击展开面板。

**30 秒验证熔断**：面板里点 **⚡ Simulate rogue** → 数字变红 🔴 → macOS 弹通知 → （若已注册 hook）Claude Code 的工具调用被拒。这是**自测**：它不注入假花费、不写 `AGENT_STOP`，只是走一遍熔断路径让你确认 hook 真的会拦；约 2 分钟后 guard 自动复位（`demo_ttl_s`），点 **Reset & rearm** 可立即恢复。

## 启用真实熔断

**本仓库不修改 `~/.claude/settings.json`，需要你手动注册**（仓库里没有任何代码会替你写这个文件）。把下面加进 `~/.claude/settings.json` 的 `hooks`，路径换成你 clone 的位置：

```json
{
  "hooks": {
    "PreToolUse":  [ { "matcher": "*", "hooks": [ { "type": "command",
        "command": "python3 \"$HOME/path/to/agentwatchdog/watchdog-guard.py\"", "timeout": 10 } ] } ],
    "PostToolUse": [ { "matcher": "*", "hooks": [ { "type": "command",
        "command": "python3 \"$HOME/path/to/agentwatchdog/watchdog-guard.py\"", "timeout": 10 } ] } ]
  }
}
```

注册后启动 app，面板会显示 `hook: ACTIVE ✓`（它按 settings.json 里是否含 `watchdog-guard` 判断）。

熔断状态通过 `~/.watchdog/state.json` 传递（app 每 15s 写，guard 每次工具调用读改写），无守护进程。**fail-open**：guard 自身出错时放行，看门狗不能变成故障点——但 state 损坏时**不会**退化成 `budget=1e9` 那种"静默失效"，而是退回 `state.json.bak` 并往 stderr 打一行。

无 GUI 时的逃生舱：

```bash
python3 watchdog-guard.py --status   # 看当前熔断状态
python3 watchdog-guard.py --reset    # 手动复位（熔断是全局的，会拒掉所有 session）
```

**三条熔断规则**（阈值可在 `~/.watchdog/config.json` 覆盖）：

| 规则 | 默认 | 行为 |
|---|---|---|
| 预算 | 今日烧钱 ≥ 日预算 | deny + 通知 + 写 `~/.claude/AGENT_STOP` 标记 |
| 循环 | 同 session 同 tool 同参数 ≥8 次/10 分钟 | deny + trip |
| 连续报错 | 同 session **连续** ≥5 次工具失败（成功即清零） | trip（下次调用起 deny） |

循环检测的指纹会忽略 `Bash` 的 `description` / `timeout` 这类纯展示字段——模型换个说法重试同一条命令，仍算同一次调用。

## 自检

```bash
./selfcheck.sh    # 14 项：计价 / demo 解析 / 三条熔断规则 / 健壮性 / 逃生舱
./build/Watchdog --stats ~/.claude/projects   # 只看数字 + hook 注册状态
```

`selfcheck.sh` **会真的失败**：任一项不过就 `exit 1`，可以直接进 CI。全程不依赖 GUI，`demo/` 夹具缺失时会自动用 `scripts/mkdemo.py` 生成。


## 文件

| 文件 | 作用 |
|---|---|
| `Watchdog.swift` | menubar app（~330 行）：JSONL 扫描/计价/预算/巡检/通知/UI |
| `watchdog-guard.py` | Pre/PostToolUse hook：预算 + 循环检测 + 连续报错三条熔断规则 |
| `watchdog-hook.sh` | ⚠️ 旧版纯预算 hook，**不再使用**，仅留作兼容/最小依赖示例 |
| `scripts/mkdemo.py` | 生成 `demo/` 夹具（selfcheck 与 build 共用） |
| `build.sh` / `selfcheck.sh` | 一键构建 + 14 项检查（不依赖 GUI，会 `exit 1`） |
| `site/index.html` | 落地页（恐惧叙事 + 规则说明 + 定价 + FAQ，两个 TODO 待填） |
| `site/launch-kit.md` | Show HN/Reddit/PH/X 发布文案包 + 发布前清单 + 止损线 |
| `demo/` | rogue 场景假数据（≈$199/日），供 selftest 与演示（由 `mkdemo.py` 生成，不入库） |

## MVP 边界（刻意不做）

- 只读本地 `~/.claude/projects`（订阅制 Claude Code），**估算值 ≠ 账单**：token × 硬编码价目表（Sonnet $3/$15、Opus $15/$75、Haiku $0.8/$4 / 1M tokens，缓存读 0.1×、写 1.25×——调价改 `priceTable`）
- 无 Cursor 熔断（云端无 hook，v1.x 仅通知）、无多机、无云
- 熔断是**全局**的：一处 trip 会拒掉所有 session，需 `--reset` 或面板复位
- 预算判定依赖 app 存活：`today_burn` 由 menubar app 每 15s 计算写入，guard 自身不算账——app 没跑就没有预算保护（循环/报错两条规则不依赖 app）
- 已知局限（`ponytail:`）：15s 全量重扫（万级 jsonl 需增量，考虑换 FSEvents）；事件保留 30min / 2000 行；语义等价但参数不同的调用不会合并；阈值 8/10min、5 次为初始值，跑一周按误报率调

## 卸载

```bash
pkill -f AgentWatchdog && rm -rf build ~/.watchdog ~/.claude/AGENT_STOP
```
