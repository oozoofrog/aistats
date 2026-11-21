"""Check standalone CLI outcome codes, errors, and interrupt behavior."""

import json
import os
import signal
import subprocess
import sys
import tempfile
import time

with tempfile.TemporaryDirectory() as folder:
    env = dict(os.environ, AISTATS_HOME=folder)

    def run(*args):
        return subprocess.run([sys.argv[1], *args], env=env, text=True, capture_output=True, timeout=5)

    names = {"startToken": "start-token", "argsContain": "args-contain", "probeFree": "probe-free",
             "purpose": "purpose", "includeToolchain": "no-toolchain", "timeoutSeconds": "timeout",
             "belowPercent": "below", "newInstancesOnly": "new-instances-only", "volumePath": "volume-path",
             "aboveGiB": "above-gib"}
    help_text = run("help").stdout
    with subprocess.Popen([sys.argv[1], "mcp"], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as server:
        for identifier, method, params in [(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                                               "clientInfo": {"name": "cli-check", "version": "1"}}),
                                           (2, "tools/list", {})]:
            server.stdin.write(json.dumps(dict(jsonrpc="2.0", id=identifier, method=method, params=params)) + "\n")
            server.stdin.flush()
            response = json.loads(server.stdout.readline())
        server.stdin.close()
        for tool in response["result"]["tools"]:
            if tool["name"] in ["find_processes", "get_environment", "diagnose_system", "wait_for"]:
                for key in tool["inputSchema"]["properties"]:
                    if key not in ["trackId", "condition"]:
                        assert "--" + names.get(key, key) in help_text, key
    found = run("find", "--pid", str(os.getpid()), "--json")
    row, = json.loads(found.stdout)["processes"]
    assert found.returncode == 0 and row["pid"] == os.getpid() and row["startToken"]
    assert run("find", "--name", "not-a-running-aistats-fixture").returncode == 3
    table = run("find", "--path", sys.executable).stdout
    assert "START TOKEN" in table and "PATH" in table
    assert "toolchain" not in json.loads(run("env", "--no-toolchain", "--json").stdout)
    diagnosis = run("diagnose", "--json")
    expected = {"issue_detected": 3, "no_clear_issue": 0, "insufficient_data": 4}
    assert diagnosis.returncode == expected[json.loads(diagnosis.stdout)["status"]]
    assert run("wait", "disk_free_above", "--above-gib", "0.001").returncode == 0
    assert run("wait", "disk_free_above", "--above-gib", "0.001", "--volume-path", "/missing-aistats-volume").returncode == 4
    assert run("wait", "process_started", "--name", "missing-aistats-fixture", "--timeout", "1").returncode == 3
    for args in [["env", "unused"], ["env", "--bogus"], ["diagnose", "--bogus"], ["find", "--name", "sleep", "--bogus"],
                 ["find", "--limit", "0"], ["find", "--port", "3", "--name", "sleep"],
                 ["wait", "cpu_idle", "--track-id", "id"], ["wait", "cpu_idle", "--timeout", "2"]]:
        result = run(*args)
        assert result.returncode == 1 and not result.stdout and result.stderr.startswith("aistats: "), args
    wait = subprocess.Popen([sys.argv[1], "wait", "process_exit", "--pid", str(os.getpid())], env=env, stdout=subprocess.PIPE)
    time.sleep(0.25)
    wait.send_signal(signal.SIGINT)
    assert wait.communicate(timeout=2)[0] == b"" and wait.returncode == 130
    print("CLI positive, negative, unknown, error and interrupt outcomes passed")
