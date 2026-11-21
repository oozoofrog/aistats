"""Check current-user TCP listener reporting against a real stdio server."""

import json
import os
import threading
import socket
import statistics
import subprocess
import sys
import tempfile
import time


def check(binary, directory):
    with subprocess.Popen([binary, "mcp"], env={**os.environ, "AISTATS_HOME": directory},
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as server:
        identifier = 0

        def request(method, params):
            nonlocal identifier
            identifier += 1
            server.stdin.write(json.dumps(dict(jsonrpc="2.0", id=identifier, method=method, params=params)) + "\n")
            server.stdin.flush()
            line = server.stdout.readline()
            if method == "tools/call":
                assert len(line.encode()) <= 4096
            return json.loads(line)["result"]

        def call(tool, **args):
            return request("tools/call", dict(name=tool, arguments=args))

        def find(port, **args):
            return call("find_processes", port=port, **args)["structuredContent"]

        try:
            request("initialize", dict(protocolVersion="2025-06-18", capabilities={}, clientInfo=dict(name="port-check", version="1")))
            server.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
            server.stdin.flush()
            schemas = {t["name"]: t["inputSchema"]["properties"] for t in request("tools/list", {})["tools"]}
            assert all("port" in schemas[n] for n in ("find_processes", "wait_for"))
            assert "port" not in schemas["track_processes"]
            for args in (dict(port=0), dict(port=65536), dict(port=True), dict(port="80"), dict(port=5, name="test"),
                         dict(port=5, match="glob"), dict(port=5, argsContain="test"), dict(port=5, startToken="1"),
                         dict(name="test", probeFree=True)):
                assert call("find_processes", **args)["isError"]
            for family, address in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
                with socket.socket(family) as listener:
                    listener.bind((address, 0))
                    port = listener.getsockname()[1]
                    assert find(port)["portState"] == "unknown"
                    assert find(port, probeFree=True)["portState"] == "in_use"
                    listener.listen()
                    expected = subprocess.check_output(["/usr/sbin/lsof", "-nP", "-a", "-u", str(os.geteuid()),
                                                        "-iTCP:" + str(port), "-sTCP:LISTEN", "-Fp"], text=True)
                    owners = {int(line[1:]) for line in expected.splitlines() if line.startswith("p")}
                    assert owners == {os.getpid()}
                    times = []
                    for _ in range(20):
                        start = time.monotonic()
                        report = find(port, match="exact", probeFree=True)
                        times.append(time.monotonic() - start)
                        assert report["portState"] == "listening" and report["matched"] == 1
                        row, = report["processes"]
                        assert row["pid"] == os.getpid() and row["startToken"] and "path" not in row
                    wait = call("wait_for", condition="port_listening", port=port, timeoutSeconds=1)["structuredContent"]
                    assert wait["state"] == "met" and wait["elapsedSeconds"] <= 0.3
                    assert wait["lastObservation"]["portListening"] and wait["matched"] == 1
                    assert wait["processes"][0]["pid"] == os.getpid()
                    print(f"{address}: 20 scans, median stdio round trip {statistics.median(times)*1000:.1f} ms")
                assert find(port, probeFree=True)["portState"] == "free"
                with socket.socket(family) as after:
                    after.bind((address, port))
                wait = call("wait_for", condition="port_listening", port=port, timeoutSeconds=1)["structuredContent"]
                assert wait["state"] == "timed_out" and "other users" in wait["reason"]
                assert wait["lastObservation"]["portListening"] is False
            with socket.socket() as ipv4, socket.socket(socket.AF_INET6) as ipv6:
                ipv6.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                ipv4.bind(("127.0.0.1", 0))
                port = ipv4.getsockname()[1]
                ipv6.bind(("::1", port))
                ipv4.listen()
                ipv6.listen()
                client_code = "import socket,sys; s=socket.create_connection(('127.0.0.1',int(sys.argv[1]))); sys.stdin.read()"
                with subprocess.Popen([sys.executable, "-c", client_code, str(port)], stdin=subprocess.PIPE) as client:
                    try:
                        with ipv4.accept()[0]:
                            row, = find(port)["processes"]
                            owner, = call("find_processes", pid=os.getpid())["structuredContent"]["processes"]
                            for key in ("pid", "name", "startToken", "ppid"):
                                assert row[key] == owner[key]
                    finally:
                        client.stdin.close()
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
                timer = threading.Timer(0.55, listener.listen)
                timer.start()
                try:
                    wait = call("wait_for", condition="port_listening", port=port, timeoutSeconds=3)["structuredContent"]
                    assert wait["state"] == "met" and 0.5 <= wait["elapsedSeconds"] <= 2.1
                finally:
                    timer.join()
                children = []
                try:
                    for _ in range(20):
                        children.append(subprocess.Popen(["/bin/sleep", "20"], pass_fds=(listener.fileno(),)))
                    report = find(port, limit=15)
                    assert report["matched"] == 21 and report["truncated"]
                    wait = call("wait_for", condition="port_listening", port=port)["structuredContent"]
                    assert wait["matched"] == 21 and 0 < len(wait["processes"]) <= 15
                finally:
                    for child in children:
                        child.terminate()
                        child.wait()
        finally:
            server.stdin.close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as directory:
        check(sys.argv[1], directory)
