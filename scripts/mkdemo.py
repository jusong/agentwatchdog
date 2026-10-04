#!/usr/bin/env python3
"""生成 demo 夹具：rogue 场景假数据（≈$199/日），供 selfcheck 与演示使用。
抽成独立脚本是为了让 selfcheck.sh 能在全新 clone 上独立跑，不依赖先跑 build.sh。"""
import json, datetime, os, sys

out_dir = sys.argv[1] if len(sys.argv) > 1 else "demo"
out = os.path.join(out_dir, "-Users-demo-rogue-app", "rogue-session.jsonl")
os.makedirs(os.path.dirname(out), exist_ok=True)
now = datetime.datetime.now(datetime.timezone.utc)


def ts(k):
    t = now - datetime.timedelta(minutes=3 * k)
    return t.strftime('%Y-%m-%dT%H:%M:') + f"{t.second:02d}.{t.microsecond // 1000:03d}Z"


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
with open(out, "w") as f:
    f.write("\n".join(lines) + "\n")
print(f"demo jsonl: {len(lines)} lines -> {out}")
