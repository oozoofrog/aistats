#!/bin/bash
# Drives `aistats mcp` over stdio against a throwaway data folder and checks every tool.
set -euo pipefail
CLI=${1:?usage: smoke-mcp.sh /path/to/aistats}
export TMPDIR=${TMPDIR:-/Volumes/eyedisk/tmp}
export AISTATS_HOME=$(mktemp -d "$TMPDIR/aistats-smoke.XXXXXX")
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; rm -rf "$AISTATS_HOME"; }
trap cleanup EXIT

init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke-agent","version":"1"}}}'
requests() {
  echo "$init"
  echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_system_stats","arguments":{}}}'
  echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_top_processes","arguments":{"sort":"memory","limit":3}}}'
  echo '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_stats_history","arguments":{"minutes":5}}}'
  echo '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nope","arguments":{}}}'
  echo '{"jsonrpc":"2.0","id":7,"method":"nope"}'
  echo 'not json'
  echo '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_stats_history","arguments":{"minutes":5,"maxPoints":0}}}'
  echo '{"jsonrpc":"1.0","id":9,"method":"ping"}'
  echo '[]'
  echo '[{"jsonrpc":"2.0","id":10,"method":"ping"}]'
  echo '42'
  echo '{"jsonrpc":"2.0","id":true,"method":"ping"}'
  echo "{\"jsonrpc\":\"2.0\",\"id\":\"$(printf 'y%.0s' $(seq 300))\",\"method\":\"ping\"}"
  echo '{"jsonrpc":"2.0","id":11,"method":"ping","result":{}}'
}

check() { echo "$OUT" | python3 -c "import json,sys
rs={}; lines=[]; nulls=[]
for l in sys.stdin:
    lines.append(l); o=json.loads(l); rs[o.get('id')]=o
    if o.get('id') is None: nulls.append(o)
def sc(i): return rs[i]['result']['structuredContent']
def size(i): return max(len(l.encode()) for l in lines if json.loads(l).get('id')==i)
$1" || { echo "FAIL: $2"; echo "$OUT" | cut -c1-600; [ -n "${SMOKE_KEEP:-}" ] && echo "$OUT" > "$SMOKE_KEEP"; exit 1; }; echo "ok - $2"; }

# 1) No app running: history reports that honestly.
OUT=$(requests | "$CLI" mcp)
check "assert rs[1]['result']['protocolVersion']=='2025-06-18' and 'diagnose_system' in rs[1]['result']['instructions']" "initialize"
check "assert [t['name'] for t in rs[2]['result']['tools']]==['get_system_stats','get_top_processes','get_stats_history','diagnose_system','find_processes','track_processes','wait_for','get_environment','get_agent_sessions']" "tools/list"
check "s=sc(3); assert s['memory']['totalBytes']>0 and (s['cpu']['usagePercent'] is None if 'cpu' in s.get('unavailable',[]) else 0<=s['cpu']['usagePercent']<=100) and len(s['topProcesses'])<=5" "get_system_stats"
check "assert len(sc(4)['processes'])==3" "get_top_processes"
check "r=rs[5]['result']; assert r['structuredContent']['recording'] is False and 'not running' in r['content'][0]['text']" "history without app"
check "assert rs[6]['error']['code']==-32602" "unknown tool is a JSON-RPC error"
check "assert rs[7]['error']['code']==-32601" "unknown method"
check "assert [o['error']['code'] for o in nulls]==[-32700,-32600,-32600,-32600,-32600,-32600], nulls" "parse error, batch, scalar, bad id and over-long id rejected"
check "assert rs[11]['error']['code']==-32600 and 'result' not in rs[11]" "a request carrying result is rejected"
check "assert rs[9]['error']['code']==-32600 and 10 not in rs" "jsonrpc 1.0 rejected, batch not executed"

# 2) Fake what the app records: 3 minutes of samples ending now.
python3 - <<'PY'
import json, os, datetime as dt
now = dt.datetime.now(dt.timezone.utc)
with open(os.path.join(os.environ['AISTATS_HOME'], 'history.jsonl'), 'w') as f:
    for i in range(90):
        t = now - dt.timedelta(seconds=2 * (89 - i))
        f.write(json.dumps({"t": t.strftime('%Y-%m-%dT%H:%M:%SZ'), "cpuPercent": float(i % 10 * 10),
            "memoryUsedPercent": 50.0, "memoryUsedBytes": 1, "memoryPressure": "warning" if i == 40 else "normal",
            "receivedBytesPerSecond": 1000.0, "sentBytesPerSecond": 10.0, "diskAvailableBytes": 10**9 - i * 10**6}) + "\n")
PY
OUT=$(requests | "$CLI" mcp)
check "s=sc(5); sm=s['summary']; assert s['recording'] and sm['cpuPercent']['max']==90 and sm['worstMemoryPressure']=='warning' and sm['diskAvailableChangeBytes']==-89000000 and len(sm['points'])==10" "history with app data (default 10 points)"
check "sm=sc(8)['summary']; assert sm['points']==[] and sm['sampleCount']==90" "history maxPoints 0 = summary only"

# 3) The app's activity log saw the calls.
check "assert all(o.get('jsonrpc')=='2.0' for o in rs.values())" "every line is JSON-RPC"
"$CLI" agents --no-attribute --calls 20 | grep -q "smoke-agent  get_stats_history (5m)" && echo "ok - activity log" || { echo "FAIL: activity log"; "$CLI" agents; exit 1; }

# 4) New tools against real processes: an idle sleeper and a child-spawning loop.
/bin/sleep 120 & SLEEPER=$!; PIDS+=("$SLEEPER")
/bin/sh -c 'sleep 1; while :; do /usr/bin/true; done' & LOOP=$!; PIDS+=("$LOOP")
/bin/sleep 2 & SHORT=$!; PIDS+=("$SHORT")
# Exits after 3 s, well before the session ends: an uncancelled wait on it would answer "met".
/bin/sleep 3 & CANCELME=$!; PIDS+=("$CANCELME")
# Same executable, told apart only by an argument (a daemon and its client).
/bin/sleep 120.5 & DAEMON=$!; PIDS+=("$DAEMON")
/bin/sleep 120.25 & CLIENT=$!; PIDS+=("$CLIENT")
sleep 0.3
call() { echo "{\"jsonrpc\":\"2.0\",\"id\":$1,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\",\"arguments\":$3}}"; }
session() {
  echo "$init"
  # Tracks first, so they run for most of the session even when the Mac is busy.
  call 30 track_processes "{\"action\":\"start\",\"pid\":$LOOP,\"includeChildren\":true,\"durationSeconds\":30,\"intervalSeconds\":1,\"spikeCpuPercent\":10}"
  call 31 track_processes '{"action":"start","name":"sleep","durationSeconds":30,"intervalSeconds":1}'
  call 20 find_processes "{\"pid\":$SLEEPER}"
  call 21 find_processes '{"name":"SLEEP","limit":15}'
  call 22 find_processes '{"path":"/bin/sl*","match":"glob","limit":3}'
  call 27 find_processes '{"path":"/bin/sleep","argsContain":"120.5"}'
  call 28 find_processes "{\"pid\":$DAEMON,\"argsContain\":\"x\"}"
  call 33 track_processes '{"action":"start","name":"sleep","argsContain":"120.5","durationSeconds":30,"intervalSeconds":1}'
  call 48 wait_for '{"condition":"cpu_idle","name":"sleep","argsContain":"120.25","belowPercent":50,"timeoutSeconds":6}'
  call 23 find_processes '{"pid":1}'
  call 24 find_processes "{\"pid\":$SLEEPER,\"startToken\":\"1\"}"
  call 25 diagnose_system '{"purpose":"heavy_work"}'
  call 26 get_environment '{}'
  # Queued behind the slow calls above, then cancelled: it must never be answered.
  call 47 get_system_stats '{}'
  echo '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":47,"reason":"smoke"}}'
  # wait_for runs while other requests are answered: ping must come back first.
  call 40 wait_for "{\"condition\":\"cpu_idle\",\"pid\":$LOOP,\"belowPercent\":0,\"timeoutSeconds\":4}"
  echo '{"jsonrpc":"2.0","id":41,"method":"ping"}'
  call 42 wait_for "{\"condition\":\"process_exit\",\"pid\":$SHORT,\"timeoutSeconds\":10}"
  call 43 wait_for "{\"condition\":\"process_exit\",\"pid\":$CANCELME,\"timeoutSeconds\":20}"
  echo '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":43,"reason":"smoke"}}'
  call 44 wait_for '{"condition":"memory_pressure_normal","timeoutSeconds":2}'
  call 45 wait_for '{"condition":"cpu_idle","timeoutSeconds":3,"belowPercent":0}'
  call 46 wait_for '{"condition":"process_exit","pid":1}'
  sleep 8
  echo '{"jsonrpc":"2.0","id":32,"method":"tools/call","params":{"name":"track_processes","arguments":{"action":"list"}}}'
  sleep 0.5
}
OUT=$(session | "$CLI" mcp)
echo "$OUT" > "$AISTATS_HOME/session.jsonl"
TRACK=$(echo "$OUT" | python3 -c "import json,sys
for l in sys.stdin:
    o=json.loads(l)
    if o.get('id')==30: print(o['result']['structuredContent']['trackId'])")
check "r=sc(20)['processes'][0]; assert r['pid']==$SLEEPER and r['name']=='sleep' and r['startToken'] and r['footprintBytes']>0 and 'path' not in r and r['ppid']>0" "find_processes by pid"
check "s=sc(21); assert s['matched']>=1 and all(p['name']=='sleep' and 'path' not in p for p in s['processes']) and s['scope']=='current_user' and len(s['processes'])<=15" "find_processes by name (case-insensitive)"
check "s=sc(22); assert len(s['processes'])<=3 and all(p['path'].startswith('/bin/sl') for p in s['processes'])" "find_processes by path glob (paths shown)"
check "r=sc(23)['processes'][0]; assert 'footprintBytes' not in r and 'footprintBytes' in r['unreadable'] and 'another user' in sc(23)['note']" "find_processes marks unreadable"
check "s=sc(24); assert s['processes']==[] and 'reused' in s['note']" "find_processes detects pid reuse"
check "s=sc(25); assert s['status'] in ('issue_detected','no_clear_issue','insufficient_data') and s['readiness'] in ('ready','caution','unknown') and len(s['evidence'])<=4 and len(s['topProcesses'])<=3" "diagnose_system"
check "s=sc(25); la=s['loadAverage']; assert len(la)==3 and all(v>=0 for v in la); print('    loadAverage', la, [e['metric'] for e in s['evidence']])" "diagnose_system loadAverage"
check "s=sc(27); assert [p['pid'] for p in s['processes']]==[$DAEMON] and s['matched']==1 and 'argsUnreadable' in s, s" "find_processes argsContain picks the daemon only"
check "assert rs[28]['result']['isError']" "argsContain with pid is rejected"
check "s=sc(33); assert s['argsFilter'] is True and 'argsUnreadable' in s and [i['pid'] for i in s['instances']]==[$DAEMON], s" "track_processes argsContain tracks the daemon only"
check "s=sc(48); assert s['state']=='met' and 'argsUnreadable' in s, s" "wait_for cpu_idle with argsContain"
check "assert not [l for l in lines if json.loads(l).get('id') in (27,33,48) and ('120.5' in l or '120.25' in l)]" "argsContain is never echoed"
check "s=sc(26); assert s['logicalCores']>0 and s['memoryBytes']>0 and s['toolchain']['swiftVersion']" "get_environment"
check "s=sc(30); assert s['state']=='running' and s['includeChildren'] and 'cpuPercent' not in s['aggregate'] and s['validSamples']==0" "track_processes start (first CPU sample null)"
check "s=sc(31); assert s['state']=='running' and s['restartCount']==0 and s['aggregate']['membersSeen']>=2" "track_processes start by name"
check "order=[json.loads(l).get('id') for l in lines]; assert order.index(41) < order.index(40), order" "ping answered while wait_for pending"
check "s=sc(40); assert s['state']=='timed_out' and s['culprits'] and s['culprits'][0]['pid']==$LOOP, s" "wait_for cpu_idle timed_out with culprits"
check "s=sc(42); assert s['state']=='met' and s['elapsedSeconds']<5" "wait_for process_exit met"
check "assert 43 not in rs" "cancelled wait sends no response (its process exited before the session ended)"
check "assert 47 not in rs" "cancelled queued call sends no response"
check "s=sc(44); assert s['state'] in ('met','timed_out') and s['lastObservation']['memoryPressure']" "wait_for memory_pressure_normal"
check "s=sc(45); assert s['state']=='timed_out' and 'culprits' in s" "wait_for system cpu_idle"
check "s=sc(46); assert s['state']=='unavailable'" "wait_for unavailable for another user's pid"
check "s=sc(32); assert any(t['trackId']=='$TRACK' and t['inThisSession'] for t in s['tracks'])" "track_processes list"
check "big=[(i,size(i)) for i in rs if i is not None and i>=20 and size(i)>4096]; assert not big, big
print('    largest tool response', max(size(i) for i in rs if i is not None and i>=20), 'bytes')" "new tool responses <= 4 KiB"

python3 -c "import json
calls=[json.loads(l) for l in open('$AISTATS_HOME/activity.jsonl')]
assert any(c['tool']=='find_processes' and c.get('detail')=='by path with args filter' for c in calls)
assert any(c['tool']=='track_processes' and c.get('detail')=='start by name with args filter' for c in calls)
assert any(c['tool']=='wait_for' and c.get('detail')=='cpu_idle with args filter' for c in calls)
assert '120.5' not in open('$AISTATS_HOME/activity.jsonl').read()" && echo "ok - activity log notes the args filter, not its text" || { echo "FAIL: activity log args filter"; exit 1; }

# 5) The session ended; its track summary is still readable from a new session.
OUT=$( (echo "$init"; call 50 track_processes "{\"action\":\"status\",\"trackId\":\"$TRACK\"}") | "$CLI" mcp)
check "s=sc(50); sp=s['spawn']; ag=s['aggregate']; assert s['state']=='stopped' and s['endReason']=='session_ended' and s['validSamples']>=3 and ag['cpuPercent']['max']>0, s
assert 'lifetimeMaxFootprintBytes' not in ag and ag.get('largestProcessLifetimePeakBytes',0)>0, ag
assert sp['method']=='kqueue+polling' and sp['forks']>=10 and sp['unattributedForks']==max(0,sp['forks']-sp['childrenAttributed']) and sum(sp['forksPerBucket'])==sp['forks'], sp
assert size(50)<=4096, size(50)
print('    forks', sp['forks'], 'attributed', sp['childrenAttributed'], 'byExecutable', sp['byExecutable'], 'spikes', len(s['spikes']), 'size', size(50))" "track status after the session ended (child spawn counts)"

# 6) CLI track for scripts: summary on stdout, rows in a JSONL file.
"$CLI" track --pid "$LOOP" --children --duration 10 --interval 1 --jsonl "$AISTATS_HOME/rows.jsonl" > "$AISTATS_HOME/track.json" 2>/dev/null
python3 -c "import json
s=json.load(open('$AISTATS_HOME/track.json')); rows=[json.loads(l) for l in open('$AISTATS_HOME/rows.jsonl')]
assert s['state']=='ended' and s['endReason']=='duration_elapsed' and s['spawn']['forks']>=10, s
assert len(rows)>=5 and rows[-1]['forks']>0, rows
print('    cli forks', s['spawn']['forks'], 'rows', len(rows))" && echo "ok - aistats track --jsonl" || { echo "FAIL: aistats track"; exit 1; }
echo "MCP smoke test passed"
