"""Verify session identity and first-agent attribution through stdio."""

import json
import os
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

with tempfile.TemporaryDirectory() as folder:
    env = dict(os.environ, AISTATS_HOME=folder)
    servers = []
    try:
        for i in range(8):
            server = subprocess.Popen([sys.argv[1], "mcp", "--name", f"probe-{i}"], env=env, text=True,
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            servers.append(server)
            message = dict(jsonrpc="2.0", id=1, method="initialize",
                           params=dict(protocolVersion="2025-06-18", capabilities={}, clientInfo=dict(name="probe", version="1")))
            server.stdin.write(json.dumps(message) + "\n")
            server.stdin.flush()
            assert "result" in json.loads(server.stdout.readline())
        records = [json.loads(p.read_text()) for p in Path(folder, "agents").glob("*.json")]
        assert len(records) == 8 and all(p["agentPid"] == os.getpid() for p in records)

        def call(**args):
            message = dict(jsonrpc="2.0", id=2, method="tools/call", params=dict(name="get_agent_sessions", arguments=args))
            server.stdin.write(json.dumps(message) + "\n")
            server.stdin.flush()
            return json.loads(server.stdout.readline())["result"]

        times = []
        for _ in range(10):
            start = time.monotonic()
            report = call(attribute=False)["structuredContent"]
            times.append(time.monotonic() - start)
            assert "busy" not in report and len(report["sessions"]) == 8 and report["caller"] == "probe-7"
        assert max(times) < 0.3
        for args in [dict(limit=0), dict(calls=21), dict(attribute="yes"), dict(calls="5")]:
            assert call(**args)["isError"]
        with subprocess.Popen(["/usr/bin/yes"], stdout=subprocess.DEVNULL) as busy:
            try:
                response = call(limit=15, calls=20)
                blob = response["content"][0]["text"].splitlines()[-1].encode()
                report = response["structuredContent"]
                assert len(blob) <= 4096 and report == json.loads(blob)
                row = next(r for r in report["busy"] if r["pid"] == busy.pid)
                assert row["agentPid"] == os.getpid() and row["startToken"]
                assert all("detail" not in c for c in report["recentCalls"])
            finally:
                busy.terminate()
        print(f"8 sessions; maximum list-only latency {max(times)*1000:.1f} ms; ranked payload {len(blob)} B")
    finally:
        for server in servers:
            server.stdin.close()
            server.wait(timeout=3)
