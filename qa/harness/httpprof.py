"""dart:io HTTP profile of one running Voyager instance, over its VM service.

  python qa/harness/httpprof.py <profile> on|off|clear|get [--grep=<substr>]

`on` turns on HttpClient timeline logging (ext.dart.io.httpEnableTimelineLogging)
so every later request made through dart:io (package:http on desktop, which
the Cloud Function callables use) is recorded; `get` lists the recorded
requests whose URI contains --grep (default `cloudfunctions`): local wall time
of the start, method, URI path, duration and status, then
`HTTPPROF <profile> <n> request(s)`. Requests made before `on` aren't
recorded. Reads qa/logs/vm_uri_<profile>.txt (launch.ps1). Read-only apart
from the profiler switch. Added 2026-10-13 for MD-14 (weather fetch counts).
"""
import asyncio, json, sys, time
from datetime import datetime
import websockets

prof, cmd = sys.argv[1], sys.argv[2]
grep = next((a.split('=', 1)[1] for a in sys.argv[3:] if a.startswith('--grep=')), 'cloudfunctions')
uri = open(f'qa/logs/vm_uri_{prof}.txt').read().strip()


async def main():
    async with websockets.connect(uri, max_size=None) as ws:
        n = 0

        async def call(method, params=None):
            nonlocal n
            n += 1
            await ws.send(json.dumps({'jsonrpc': '2.0', 'id': str(n), 'method': method, 'params': params or {}}))
            while True:
                m = json.loads(await ws.recv())
                if m.get('id') == str(n):
                    if 'error' in m: raise SystemExit(f'{method}: {m["error"]}')
                    return m['result']

        vm = await call('getVM')
        iso = next((i for i in vm['isolates'] if i['name'] == 'main'), vm['isolates'][0])['id']
        if cmd in ('on', 'off'):
            await call('ext.dart.io.httpEnableTimelineLogging', {'isolateId': iso, 'enabled': cmd == 'on'})
            print(f'HTTPPROF {prof} logging {cmd}')
        elif cmd == 'clear':
            await call('ext.dart.io.clearHttpProfile', {'isolateId': iso})
            print(f'HTTPPROF {prof} cleared')
        else:
            r = await call('ext.dart.io.getHttpProfile', {'isolateId': iso})
            now_wall, now_tl = time.time(), r['timestamp']
            reqs = sorted((q for q in r['requests'] if grep in q['uri']), key=lambda q: q['startTime'])
            for q in reqs:
                start = datetime.fromtimestamp(now_wall - (now_tl - q['startTime']) / 1e6)
                end = q.get('endTime')
                dur = f'{(end - q["startTime"]) / 1000:.0f}ms' if end else 'open'
                status = (q.get('response') or {}).get('statusCode', '-')
                print(start.strftime('%H:%M:%S.%f')[:-3], q['method'], q['uri'].split('.net')[-1], dur, status)
            print(f'HTTPPROF {prof} {len(reqs)} request(s) matching {grep}')


asyncio.run(main())
