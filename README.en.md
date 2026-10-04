# AgentWatchdog 🐕

**A circuit breaker for your AI coding agents.** A macOS menubar app that watches Claude Code sessions and *stops* agents when they go rogue — not just another usage meter.

```
Your agents run at 3am. Who stops them when they go rogue?
```

## Why

It happens every month: [$16.6M billed](https://en.kocpc.com.tw/archives/474) to a dev running 8 agents (dashboard showed $0), [$6,000 overnight](https://www.makeuseof.com/someone-left-claude-code-running-overnight-and-it-cost-6000/), [$187 in 10 minutes](https://news.ycombinator.com/item?id=47133305), [16M tokens for a 3-line fix](https://forum.cursor.com/t/agent-mode-claude-thinking-burned-16-million-tokens-for-a-3-line-fix/169158).

Every existing tool (ccusage, CodexBar, a dozen menubar monitors) only **watches** — after the money is gone. The "stop" layer was empty: in-process SDKs can't see subscription sessions, proxy gateways can't intercept them, and the [official kill-switch recipe](https://github.com/anthropics/cwc-long-running-agents) is a manual switch. AgentWatchdog lives at the one enforcement point that works for subscription sessions: **Claude Code hooks**.

## What it does

| Rule | Default | Action |
|---|---|---|
| **Budget** | today's estimated spend ≥ your daily $ limit | trip: notification + stop marker + deny tool calls |
| **Loop** | same tool + same arguments ≥8× within 10 min | trip + deny |
| **Error streak** | ≥5 consecutive tool failures in a session | trip + deny on next call |

Plus: live today/7d spend in the menubar, top sessions by project, patrol panel (running agent processes), one-click "⚡ Simulate rogue" demo, one-click rearm. **Fail-open**: if the watchdog itself fails, your agents keep running.

Everything is local: it reads `~/.claude/projects/*.jsonl` and official hooks. No cloud, no accounts, no telemetry. Cost figures are estimates (tokens × list prices incl. cache), not invoices.

## Install

```bash
git clone https://github.com/jusong/agentwatchdog.git && cd agentwatchdog
./build.sh        # compile + selftest + bundle + launch
./selfcheck.sh    # 6 checks: metering, budget deny/allow, loop, error streak
```

Or download the prebuilt app (TODO: Gumroad link, $19 one-time — or just build from source).

## Register the guard (real enforcement)

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse":  [ { "matcher": "*", "hooks": [ { "type": "command",
        "command": "python3 /path/to/agentwatchdog/watchdog-guard.py", "timeout": 10 } ] } ],
    "PostToolUse": [ { "matcher": "*", "hooks": [ { "type": "command",
        "command": "python3 /path/to/agentwatchdog/watchdog-guard.py", "timeout": 10 } ] } ]
  }
}
```

Tune thresholds via `~/.watchdog/config.json` (`loop_n`, `loop_window_s`, `err_streak`).

## How it works

- `Watchdog.swift` (~330 lines, SwiftUI MenuBarExtra): scans session JSONL, dedupes by message id (ccusage-style), prices with a hardcoded table (edit `priceTable` when Anthropic changes prices), writes `~/.watchdog/state.json` every 15s.
- `watchdog-guard.py`: Pre/PostToolUse hook. Reads state, appends to `events.jsonl`/`errors.jsonl` (sliding window), enforces the three rules, emits `permissionDecision: deny` on trip. Fail-open on any error.
- No daemon, no IPC beyond two JSON files.

## Limitations (on purpose)

- Claude Code only (v1) — Cursor agents run cloud-side, no local hooks; notifications on the roadmap
- Estimates ≠ invoices; subscription quotas are translated into your $ budget
- Loop detection matches exact arguments (semantically-equal-but-different calls won't dedupe)
- A safety net, not a guarantee: it shrinks the blast radius of rogue agents; it does not promise zero incidents

## License

MIT. Use it, fork it, ship it.
