#!/usr/bin/env python3
"""AgentWatchdog guard — Claude Code PreToolUse/PostToolUse hook.
规则：预算熔断 / 循环检测(同 tool+参数 滑窗 N 次) / 连续报错(K 次)。
状态：~/.watchdog/state.json(与 menubar app 共享) + events.jsonl / errors.jsonl
用法：stdin 传入 hook JSON；超限输出 deny JSON。无守护进程。"""
import sys, os, json, time, hashlib, subprocess

WATCHDOG_DIR = os.environ.get("WATCHDOG_HOME", os.path.expanduser("~/.watchdog"))
STATE = os.path.join(WATCHDOG_DIR, "state.json")
EVENTS = os.path.join(WATCHDOG_DIR, "events.jsonl")
ERRORS = os.path.join(WATCHDOG_DIR, "errors.jsonl")

DEFAULTS = {"loop_n": 8, "loop_window_s": 600, "err_streak": 5}  # ponytail: 阈值先拍脑袋，跑一周按误报率调


def cfg():
    c = dict(DEFAULTS)
    try:
        c.update(json.load(open(os.path.join(WATCHDOG_DIR, "config.json"))))
    except Exception:
        pass
    return c


def read_state():
    try:
        return json.load(open(STATE))
    except Exception:
        return {"today_burn": 0.0, "budget": 1e9, "tripped": False, "reason": ""}


def write_state(**kw):
    s = read_state()
    s.update(kw)
    os.makedirs(WATCHDOG_DIR, exist_ok=True)
    json.dump(s, open(STATE, "w"))


def deny(reason):
    print(json.dumps({
        "decision": "block", "reason": reason,
        "hookSpecificOutput": {"hookEventName": "PreToolUse",
                               "permissionDecision": "deny",
                               "permissionDecisionReason": reason}}))
    sys.exit(0)


def notify(title, body):
    if os.environ.get("WATCHDOG_SILENT"):  # 测试时静音
        return
    try:
        subprocess.run(["osascript", "-e",
                        f'display notification "{body}" with title "AgentWatchdog" subtitle "{title}"'],
                       timeout=3, capture_output=True)
    except Exception:
        pass


def trip(reason):
    write_state(tripped=True, reason=reason, tripped_at=time.strftime("%Y-%m-%dT%H:%M:%S"))
    notify("Circuit breaker TRIPPED", reason)


def append(path, obj, cap=600):
    os.makedirs(WATCHDOG_DIR, exist_ok=True)
    with open(path, "a") as f:
        f.write(json.dumps(obj) + "\n")
    if os.path.getsize(path) > 64 * 1024:  # ponytail: 粗粒度截断，够用
        lines = open(path).readlines()[-cap:]
        open(path, "w").writelines(lines)


def load_lines(path):
    try:
        return [json.loads(l) for l in open(path) if l.strip()]
    except Exception:
        return []


def main():
    try:
        hook = json.load(sys.stdin)
    except Exception:
        sys.exit(0)  # 坏输入直接放行：看门狗自己不能变成故障点
    event = hook.get("hook_event_name", "")
    session = hook.get("session_id", "unknown")[:12]
    state = read_state()
    c = cfg()

    if event == "PostToolUse":  # 记录报错 → 连续 K 次熔断
        resp = hook.get("tool_response") or {}
        if resp.get("is_error") or (isinstance(resp.get("error"), (str, dict)) and resp.get("error")):
            append(ERRORS, {"ts": time.time(), "session": session})
            streak, errs = 0, load_lines(ERRORS)
            for e in reversed(errs):
                if e.get("session") != session:
                    break
                streak += 1
            if streak >= c["err_streak"] and not state.get("tripped"):
                trip(f"error streak: {streak} consecutive tool failures in session {session}")
        sys.exit(0)

    # ---- PreToolUse ----
    if state.get("tripped"):
        deny(f"AgentWatchdog tripped: {state.get('reason', 'manual')} — reset in the menubar app")
    burn, budget = state.get("today_burn", 0.0), state.get("budget", 1e9)
    if burn >= budget:
        trip(f"budget ${budget:.2f} exceeded (burn ${burn:.2f})")
        deny(f"AgentWatchdog: daily budget ${budget:.2f} exceeded (burn ${burn:.2f})")

    tool = hook.get("tool_name", "?")
    h = hashlib.md5(json.dumps(hook.get("tool_input", {}), sort_keys=True).encode()).hexdigest()[:16]
    now = time.time()
    append(EVENTS, {"ts": now, "session": session, "tool": tool, "h": h})
    repeats = sum(1 for e in load_lines(EVENTS)
                  if e.get("session") == session and e.get("h") == h and now - e.get("ts", 0) <= c["loop_window_s"])
    if repeats >= c["loop_n"]:
        trip(f"loop detected: {tool} ×{repeats} identical calls in {c['loop_window_s']//60}min (session {session})")
        deny(f"AgentWatchdog: {tool} called {repeats}× with identical args within "
             f"{c['loop_window_s']//60}min — loop detected, tripped. Reset in menubar.")
    sys.exit(0)


if __name__ == "__main__":
    main()
