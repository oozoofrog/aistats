"""Exercise origin selection across a real intermediate process and a disk writer."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def rpc(server, method, params):
    server.stdin.write(json.dumps(dict(jsonrpc="2.0", id=1, method=method, params=params)) + "\n")
    server.stdin.flush()
    return json.loads(server.stdout.readline())["result"]


with tempfile.TemporaryDirectory() as home:
    env = dict(os.environ, AISTATS_HOME=home)
    script = """import os,sys,time
with open(sys.argv[1]+"/writer.pid","w") as p: p.write(str(os.getpid()))
with open(sys.argv[1]+"/counter","wb") as f:
 for _ in range(1500):
  f.seek(0); f.write(os.urandom(8192)); f.flush(); os.fsync(f.fileno()); time.sleep(.015)
"""
    with subprocess.Popen([sys.argv[1], "mcp"], env=env, text=True,
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE) as server:
        rpc(server, "initialize", dict(protocolVersion="2025-06-18", capabilities={},
                                       clientInfo=dict(name="origin-check", version="1")))

        def call(name, **args):
            result = rpc(server, "tools/call", dict(name=name, arguments=args))
            if not result["isError"]:
                blob = result["content"][0]["text"].splitlines()[-1].encode()
                assert len(blob) <= 4096 and json.loads(blob) == result["structuredContent"]
            return result

        def sessions(**args):
            result = call("get_agent_sessions", **args)
            assert not result["isError"], result
            return result["structuredContent"]

        try:
            # The shell waits so its PID remains observable between the writer and agent.
            shell = subprocess.Popen(["sh", "-c", '"$@" & wait', "sh", sys.executable, "-c", script, home])
            try:
                pidfile = Path(home, "writer.pid")
                for _ in range(200):
                    if pidfile.exists() and pidfile.read_text(): break
                    time.sleep(.02)
                writer = int(pidfile.read_text())
                try:
                    identity = call("find_processes", pid=writer)["structuredContent"]["processes"][0]
                    key = {k: identity[k] for k in ("pid", "startToken")}
                    full = sessions(origin=True, ancestor=key, sort="disk", limit=1)
                    row = full["busy"][0]
                    assert row["pid"] == writer and row["writtenBytes"] > 0 and row["diskBytesPerSecond"] > 0
                    assert [n["pid"] for n in row["chain"]] == [writer, shell.pid, os.getpid()]
                    assert row["agentPid"] == os.getpid()
                    session = full["sessions"][0]
                    selected = dict(pid=session["serverPid"], startToken=session["serverStartToken"])
                    by_session = sessions(origin=True, session=selected, sort="memory", limit=2)["busy"]
                    assert by_session and all(r["agentPid"] == os.getpid() for r in by_session)
                    assert sessions(origin=True, ancestor=dict(pid=writer, startToken="1"))["busy"] == []
                    assert sessions(origin=True, session=dict(pid=server.pid, startToken="1"))["busy"] == []
                    for args in [dict(sort="disk"), dict(origin=True, sort="bad"), dict(origin=True, attribute=False),
                                 dict(origin=True, session=selected, ancestor=key), dict(origin=True, ancestor=dict(pid=True, startToken="1"))]:
                        assert call("get_agent_sessions", **args)["isError"]
                    for form in ["text", "json"]:
                        result = call("get_process_tree", sort="disk", limit=15, format=form)
                        assert not result["isError"], result
                        tree = result["structuredContent"]
                        if form == "json":
                            agent = next(a for a in tree["agents"] if a["pid"] == os.getpid())
                            assert agent["serverPid"] == server.pid and agent["processCount"] >= 4
                            assert agent["diskBytesPerSecond"] > 0
                            assert all(r["unattributed"] for r in tree["unattributed"])
                        else:
                            assert "serverPid=" in tree["text"] and "출발점 불명" in tree["text"]
                    for metric in ["cpu", "mem", "disk"]:
                        result = subprocess.run([sys.argv[1], "tree", "--sort", metric], capture_output=True,
                                                env=env, text=True, check=True)
                        assert str(os.getpid()) in result.stdout and "호스트 앱" in result.stdout
                    print("Verified three CLI sorts and bounded MCP tree results in text and JSON.")
                    print("Verified disk counters, process → shell → agent chain, both selectors and stale identities.")
                finally:
                    os.kill(writer, 15)
            finally:
                shell.wait(timeout=5)
        finally:
            server.stdin.close()
