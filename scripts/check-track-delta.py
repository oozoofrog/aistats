"""Verify that independent MCP processes can resume the same track."""
import contextlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


@contextlib.contextmanager
def session(binary, home):
    with subprocess.Popen([binary, "mcp"], env=dict(os.environ, AISTATS_HOME=home),
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as server:
        def request(method, params):
            server.stdin.write(json.dumps(dict(jsonrpc="2.0", id=1, method=method, params=params)) + "\n")
            server.stdin.flush()
            return json.loads(server.stdout.readline())["result"]

        def track(expect_error=False, **args):
            result = request("tools/call", dict(name="track_processes", arguments=args))
            assert result["isError"] == expect_error, result
            if expect_error:
                return None
            return result["structuredContent"]

        try:
            request("initialize", dict(protocolVersion="2025-06-18", capabilities={},
                                       clientInfo=dict(name="cursor-check", version="1")))
            yield track
        finally:
            server.stdin.close()


with tempfile.TemporaryDirectory() as home:
    with session(sys.argv[1], home) as first:
        track_id = first(action="start", pid=os.getpid())["trackId"]
        first(action="stop", trackId=track_id)
        base = first(action="status", trackId=track_id)
        assert len(base["cursor"].encode()) <= 64

    with session(sys.argv[1], home) as second:
        status = dict(action="status", trackId=track_id)
        for action in ["start", "list", "stop"]:
            second(expect_error=True, action=action, since=base["cursor"])
        malformed = second(**status, since="t-bad")
        assert malformed["delta"] is False and malformed["deltaReset"] == "unknown_cursor"
        for suffix in ["01", "+1"]:
            fake_snapshot = "s-12345678-1234-1234-1234-123456789abc-" + suffix
            assert second(**status, since=fake_snapshot)["deltaReset"] == "unknown_cursor"
        another = second(action="start", pid=os.getpid())["trackId"]
        other = second(action="status", trackId=another, since=base["cursor"])
        assert other["deltaReset"] == "other_target"
        second(action="stop", trackId=another)
        delta = second(**status, since=base["cursor"])
        assert delta["delta"] and delta["state"] == base["state"]
        assert set(delta["unchanged"]) == {"config", "instances", "members", "events", "spikes", "spawn", "notes"}
        size = len(json.dumps(delta, separators=(",", ":")).encode())
        assert size <= 800, size
        for _ in range(8):
            second(**status)
        assert second(**status, since=base["cursor"])["deltaReset"] == "expired"
        index = Path(home, "tracks", track_id + ".cursors", "index.json")
        assert index.stat().st_mode & 0o777 == 0o600
        assert len(json.loads(index.read_text())) == 8
        print(f"Cross-session delta {size} bytes. Eight private bases retained.")
