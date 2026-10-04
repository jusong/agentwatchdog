#!/usr/bin/env python3
"""AgentWatchdog guard — Claude Code PreToolUse/PostToolUse hook.
规则：预算熔断 / 循环检测(同 tool+参数 滑窗 N 次) / 连续报错(K 次，成功即清零)。
状态：~/.watchdog/state.json(与 menubar app 共享) + events.jsonl / results.jsonl
用法：stdin 传入 hook JSON；超限输出 deny JSON。无守护进程。
      --status 打印当前熔断状态；--reset 手动复位（无 GUI 时的逃生舱）。"""
import sys, os, json, time, hashlib, subprocess

WATCHDOG_DIR = os.environ.get("WATCHDOG_HOME", os.path.expanduser("~/.watchdog"))
STATE = os.path.join(WATCHDOG_DIR, "state.json")
BAK = os.path.join(WATCHDOG_DIR, "state.json.bak")
EVENTS = os.path.join(WATCHDOG_DIR, "events.jsonl")
RESULTS = os.path.join(WATCHDOG_DIR, "results.jsonl")

DEFAULTS = {"loop_n": 8, "loop_window_s": 600, "err_streak": 5,  # ponytail: 阈值先拍脑袋，跑一周按误报率调
            "demo_ttl_s": 120}
RETENTION_S = 1800   # 事件保留 30min，必须 > loop_window_s，否则滑窗会被截断
MAX_LINES = 2000     # 兜底上限；原来 600 太短，并发 session 下会把滑窗冲没

# Claude Code 会在 tool_input 里带纯展示用的字段。Bash 的 description 是给人看的标签，
# 模型换个说法重试同一条命令时，只有 description 变了 —— 按原始参数哈希就会漏掉这种真循环。
# 参考 loop-breaker：只在确定是装饰字段的工具上剥掉，宁可漏报也不要误杀正常调用。
COSMETIC_KEYS = {"Bash": ("description", "timeout")}


def cfg():
    c = dict(DEFAULTS)
    try:
        c.update(json.load(open(os.path.join(WATCHDOG_DIR, "config.json"))))
    except Exception:
        pass
    return c


def _default_state():
    # 首次运行(文件不存在)才是这个值。损坏走 read_state 的 .bak 分支，不会落到这。
    return {"today_burn": 0.0, "budget": 1e9, "tripped": False, "reason": ""}


def read_state():
    for path, why in ((STATE, "primary"), (BAK, "backup")):
        try:
            with open(path) as f:
                return json.load(f)
        except FileNotFoundError:
            if path == BAK:
                return _default_state()   # 两个都没有 = 首次运行，正常
        except Exception as e:
            # 损坏就退到备份，而不是退到 budget=1e9 —— 后者会让熔断静默消失
            print(f"watchdog-guard: {why} state unreadable ({e}), falling back", file=sys.stderr)
    return _default_state()


def write_state(**kw):
    s = read_state()
    s.update(kw)
    os.makedirs(WATCHDOG_DIR, exist_ok=True)
    try:
        if os.path.exists(STATE):
            with open(STATE) as f:
                json.load(f)          # 只在当前文件确实完好时才更新 .bak
            with open(BAK, "w") as f:
                json.dump(s, f)
    except Exception:
        pass
    tmp = f"{STATE}.tmp.{os.getpid()}"   # 原子替换：进程被 kill 时旧文件仍在，不会写坏
    with open(tmp, "w") as f:
        json.dump(s, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, STATE)


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


def trip(reason, demo=False):
    write_state(tripped=True, reason=reason, trip_demo=bool(demo),
                tripped_ts=time.time(), tripped_at=time.strftime("%Y-%m-%dT%H:%M:%S"))
    notify("Circuit breaker TRIPPED", reason)


def reset(**kw):
    s = read_state()
    s.update({"tripped": False, "reason": "", "trip_demo": False, "tripped_ts": 0})
    s.update(kw)
    write_state(**s)
    for p in (EVENTS, RESULTS):
        try:
            os.remove(p)
        except FileNotFoundError:
            pass


def append(path, obj):
    os.makedirs(WATCHDOG_DIR, exist_ok=True)
    with open(path, "a") as f:
        f.write(json.dumps(obj, default=str) + "\n")


def trim(path, retention_s=RETENTION_S):
    """按时间窗回收，而不是按行数硬砍 —— 行数砍会让滑窗在并发 session 下失效。"""
    try:
        cutoff = time.time() - retention_s
        keep = []
        with open(path) as f:
            for line in f:
                if not line.strip():
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get("ts", 0) >= cutoff:
                    keep.append(line)
        if len(keep) > MAX_LINES:
            keep = keep[-MAX_LINES:]
        tmp = f"{path}.tmp.{os.getpid()}"
        with open(tmp, "w") as f:
            f.writelines(keep)
        os.replace(tmp, path)
    except FileNotFoundError:
        pass
    except Exception as e:
        print(f"watchdog-guard: trim {path} failed ({e})", file=sys.stderr)


def load_lines(path):
    """逐行解析，跳过坏行。一行截断不能让整份历史消失。"""
    out = []
    try:
        with open(path) as f:
            for line in f:
                if not line.strip():
                    continue
                try:
                    out.append(json.loads(line))
                except Exception:
                    continue
    except Exception:
        return out        # 读不到就当作没有历史，不清空已解析的部分
    return out


def fingerprint(tool, tool_input):
    drop = COSMETIC_KEYS.get(tool, ())
    d = {k: v for k, v in (tool_input or {}).items() if k not in drop}
    return hashlib.md5(json.dumps(d, sort_keys=True, default=str).encode()).hexdigest()[:16]


def check_state(s, c):
    """返回要 deny 的原因；不需要拦截则返回 None。"""
    if s.get("tripped"):
        # 演示性熔断自动复位，免得点一下自测按钮就把 agent 锁死到明天
        if s.get("trip_demo") and time.time() - float(s.get("tripped_ts") or 0) > c["demo_ttl_s"]:
            reset()
            return None
        hint = "auto-rearms shortly" if s.get("trip_demo") else "reset in the menubar app or: watchdog-guard.py --reset"
        return f"AgentWatchdog tripped: {s.get('reason', 'manual')} — {hint}"
    burn, budget = s.get("today_burn", 0.0), s.get("budget", 1e9)
    if burn >= budget:
        trip(f"budget ${budget:.2f} exceeded (burn ${burn:.2f})")
        return f"AgentWatchdog: daily budget ${budget:.2f} exceeded (burn ${burn:.2f})"
    return None


def main():
    args = set(sys.argv[1:])
    if args & {"--reset", "--status"}:
        if "--reset" in args:
            reset()
            print("breaker rearmed")
        print(json.dumps(read_state(), ensure_ascii=False, indent=2))
        sys.exit(0)

    try:
        hook = json.load(sys.stdin)
    except Exception:
        sys.exit(0)  # 坏输入直接放行：看门狗自己不能变成故障点

    event = hook.get("hook_event_name", "")
    session = hook.get("session_id", "unknown")[:12]
    c = cfg()

    try:
        if event == "PostToolUse":
            resp = hook.get("tool_response") or {}
            failed = bool(resp.get("is_error")) or bool(resp.get("error"))
            # 成功也要记一条：连续语义靠成功清零，只记失败就退化成"本 session 累计失败数"
            append(RESULTS, {"ts": time.time(), "session": session, "ok": not failed})
            trim(RESULTS)
            if failed:
                streak = 0
                for e in reversed(load_lines(RESULTS)):
                    if e.get("session") != session:
                        continue      # 别的 session 不打断本 session 的连续计数
                    if e.get("ok"):
                        break         # 成功即清零
                    streak += 1
                if streak >= c["err_streak"] and not read_state().get("tripped"):
                    trip(f"error streak: {streak} consecutive tool failures in session {session}")
            sys.exit(0)

        if event != "PreToolUse":
            sys.exit(0)

        reason = check_state(read_state(), c)
        if reason:
            deny(reason)

        tool = hook.get("tool_name", "?")
        h = fingerprint(tool, hook.get("tool_input"))
        now = time.time()
        append(EVENTS, {"ts": now, "session": session, "tool": tool, "h": h})
        trim(EVENTS)
        repeats = sum(1 for e in load_lines(EVENTS)
                      if e.get("session") == session and e.get("h") == h and now - e.get("ts", 0) <= c["loop_window_s"])
        if repeats >= c["loop_n"]:
            trip(f"loop detected: {tool} ×{repeats} identical calls in {c['loop_window_s']//60}min (session {session})")
            deny(f"AgentWatchdog: {tool} called {repeats}× with identical args within "
                 f"{c['loop_window_s']//60}min — loop detected, tripped. Reset in menubar.")
    except SystemExit:
        raise
    except Exception as e:
        # 兜底 fail-open：规则引擎自己出错时放行，看门狗不能变成故障点
        print(f"watchdog-guard: internal error ({e}) — allowing", file=sys.stderr)
    sys.exit(0)


if __name__ == "__main__":
    main()
