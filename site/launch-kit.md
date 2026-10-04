# AgentWatchdog 发布文案包

> 目标：D11（构建第 11 天）按两周计划发布。主渠道 Show HN，副渠道 r/ClaudeAI、r/cursor、PH、X。

## 0. 发布前清单（缺一不发）

- [ ] 30–45s GIF：menubar 面板 → 点 ⚡ Simulate rogue → 变红 🔴 → 通知弹出 → Reset（这是转化核心，一条 GIF 讲完产品）
- [ ] 落地页上线（site/index.html，两个 TODO：Gumroad 链接、联系邮箱），绑域名
- [ ] Gumroad/LemonSqueezy 上架：$19（划线 $29），14 天退款
- [ ] 自检全绿：`./selfcheck.sh` 6 项 PASS
- [ ] 发布时间：**周二–周四，美西 8–10am**（PT 午间前是 HN 流量窗口）
- [ ] 发布后前 3 小时守着回评论（Show HN 的生死在前 3 小时）

## 1. Show HN

**标题（选一）**：
1. `Show HN: AgentWatchdog – A circuit breaker for AI coding agents that go rogue`
2. `Show HN: I built a kill switch for Claude Code after the $187-in-10-minutes stories`
3. `Show HN: Menubar watchdog that stops your AI agents before they burn your budget`

（推荐 1：说清品类；2 的叙事强但更像个例报复；3 稍营销腔）

**正文**（Show HN 惯例：短、事实、无营销词）：

> Hey HN — I built a macOS menubar app that watches Claude Code sessions and trips a circuit breaker when an agent goes rogue.
>
> Three rules: a daily $ budget breaker, loop detection (same tool + same arguments 8× within 10 minutes), and an error-streak kill (5 consecutive tool failures). When a rule trips you get a notification, the menubar turns red, and every further tool call is denied through official Claude Code hooks until you rearm it.
>
> The metering reads the local session logs directly (~/.claude/projects JSONL), so it works with subscription plans, not just API keys. Everything stays on your machine — no cloud, no accounts, no telemetry. It's a one-time $19, because paying a monthly subscription for spend protection felt wrong.
>
> I built it after collecting too many of these stories: an agent loop that cost $187 in 10 minutes (https://news.ycombinator.com/item?id=47133305), a $6,000 overnight session, and Cursor burning 16M tokens on a 3-line fix. The existing tools all watch — ccusage, CodexBar — but none of them stop anything. This one stops.
>
> Happy to answer anything about the hook mechanics or the pricing.

**预埋首评**（发布后立即自己跟一条，讲设计取舍）：

> On design choices, since they'll come up:
>
> - Why hooks instead of an SDK/proxy? In-process SDKs can't see subscription sessions, and proxy gateways assume traffic routes through you (subscription OAuth traffic doesn't). Claude Code's PreToolUse/PostToolUse hooks are an official enforcement point, so that's where the breaker lives.
> - Fail-open: if the watchdog itself crashes, your agents keep running. A safety tool that can brick your workflow is worse than no safety tool.
> - The $ numbers are estimates (tokens × list prices incl. cache), not your invoice — subscription quotas aren't denominated in dollars, so I translate everything into a $ budget you set.
> - Roadmap: Cursor background-agent billing alerts (they're cloud-side, so v1 can only notify), cron/patrol coverage, and a rules editor. Not on the roadmap: your data leaving your machine.

## 2. r/ClaudeAI 变体

> **标题**：I kept reading "burned through my 5h window overnight" posts, so I built a circuit breaker for Claude Code
>
> 正文：menubar app + hooks。三条规则（预算/循环/连续报错）。贴 GIF。最后一段：**"To be clear on scope: this guards local Claude Code sessions (including cron/long-running ones). I'm not affiliated with Anthropic. Happy to answer questions here."**（Reddit 对自推敏感，透明度拉满；版规允许 Show off your work 类发帖才发，先看版规/sidebar）

## 3. r/cursor 变体（诚实定位，别过度承诺）

> **标题**：For the "agent burned my credits overnight" crowd — I built a watchdog (Cursor = alerts for now, full support exploring)
>
> 正文：讲清 Cursor 的 background agent 在云端、本地 hook 够不到，v1 只做 Claude Code 熔断 + Cursor 账单异常通知（roadmap）。蹭的是他们 16M-token 帖子的情绪，但**不**宣称能拦 Cursor。

## 4. Product Hunt

- **Tagline**: `The kill switch your AI agents didn't come with.`
- **First comment**：复用 Show HN 首评的取舍段 + GIF。

## 5. X 线程骨架（5 条）

1. hook：上个月有人一觉醒来收到 $6,000 的 Claude 账单。还有人 10 分钟烧掉 $187。工具都会"看"，没人会"停"。（配 4 张卡片截图）
2. 所以我做了 AgentWatchdog：menubar 常驻，三条熔断规则（预算/循环/连续报错）。
3. GIF： rogue agent 被拦下的全程 30 秒。
4. 全本地：读的是本地会话日志，官方 hooks 执行，零遥测。买断 $19，不搞订阅。
5. 链接 + "如果你也有 agent 跑飞的故事，回复区收"（UGC 钩子）。

## 6. 定价与止损（来自 go-plan，发布时照做）

- $19 买断（划线 $29）——此人群 75% 收入来自买断（AI Toolbox 实证），订阅必死
- **止损线：发布后 14 天，Show HN <50 分且零付费 → 停，转开源核心 + 卖 Pro（云同步周报/团队视图）**
- 最大风险：Anthropic 原生加每日限额 → 若发生，立刻转向跨工具中立层（Cursor 通知 + cron 巡检是没人做的部分）

## 7. 素材复用

- 恐惧叙事卡片（4 个事件 + 链接）在落地页 index.html 里，直接截图发推
- `./selfcheck.sh` 的 6 项 PASS 输出可截图当"工程可信度"素材
