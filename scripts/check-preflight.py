"""Exercise the preflight hook with a private history and session store."""

import datetime
import json
import os
import stat
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

with tempfile.TemporaryDirectory() as folder:
    env = dict(os.environ, AISTATS_HOME=folder)
    command = [sys.argv[1], "preflight"]

    def run(*args, data="{}"):
        return subprocess.run(command + list(args), input=data, capture_output=True, text=True, env=env, timeout=2)

    history = Path(folder, "history.jsonl")

    def sample(age):
        stamp = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=age)
        history.write_text(json.dumps(dict(t=stamp.strftime("%Y-%m-%dT%H:%M:%SZ"), cpuPercent=99,
                                           memoryPressure="normal")) + "\n")

    sample(20)
    assert json.loads(run("--json").stdout)["cpuSource"] == "none"
    sample(2)
    human = run("--json")
    report = json.loads(human.stdout)
    assert human.returncode == 3 and report["readiness"] == "caution"
    assert any(s["metric"] == "cpu" and s["observed"] == 99 and s["threshold"] == 85 for s in report["signals"])
    times = []
    for agent in ["claude-code", "codex"] * 10:
        start = time.monotonic()
        reply = run("--agent", agent)
        times.append(1000 * (time.monotonic() - start))
        assert reply.returncode == 0 and not reply.stderr
        output = json.loads(reply.stdout)
        assert list(output) == ["hookSpecificOutput"]
        hook = output["hookSpecificOutput"]
        assert set(hook) == {"additionalContext", "hookEventName"} and hook["hookEventName"] == "PreToolUse"
        assert len(hook["additionalContext"].encode()) <= 512
    assert run("--agent", "codex", data='{"session_id":"a"}').stdout
    assert not run("--agent", "codex", data='{"session_id":"a"}').stdout
    assert stat.S_IMODE(Path(folder, "preflight-sessions.json").stat().st_mode) == 0o600
    for reply in [run("--agent", "invalid"), run("--agent", "codex", "--bad"), run("--agent", "codex", data="malformed")]:
        assert reply.returncode == 0 and not reply.stdout and reply.stderr.startswith("aistats: ")
    print(f"20 calls: median {statistics.median(times):.1f} ms, maximum {max(times):.1f} ms")
    assert max(times) < 200
