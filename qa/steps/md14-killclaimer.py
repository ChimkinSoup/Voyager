"""MD-14.1: kill whichever device claims the weather fetch lock, mid-fetch.

  python qa/steps/md14-killclaimer.py <uid> <timeout_s> <deviceIdPrefixA>=qa <deviceIdPrefixB>=qb

Polls users/<uid>/sync_locks/weather_fetch every 100 ms (read-only REST);
as soon as it exists, runs `stop.ps1 -Profile <claimer>` and prints the
times. Ends with KILLED <profile> or NO-CLAIM.
"""
import json, subprocess, sys, time, urllib.request, urllib.error
from datetime import datetime

uid, timeout = sys.argv[1], float(sys.argv[2])
who = dict(a.split('=') for a in sys.argv[3:])
tok = subprocess.run('gcloud auth print-access-token', shell=True, capture_output=True, text=True).stdout.strip()
url = f'https://firestore.googleapis.com/v1/projects/voyager-db9de/databases/(default)/documents/users/{uid}/sync_locks/weather_fetch'
now = lambda: datetime.now().strftime('%H:%M:%S.%f')[:-3]
end = time.time() + timeout
while time.time() < end:
    try:
        j = json.load(urllib.request.urlopen(urllib.request.Request(url, headers={'Authorization': 'Bearer ' + tok}), timeout=5))
    except Exception:
        time.sleep(0.1)
        continue
    dev = j['fields']['deviceId']['stringValue']
    prof = next(p for k, p in who.items() if dev.startswith(k))
    print(now(), 'lock seen', dev, 'updateTime', j['updateTime'], '-> stopping', prof, flush=True)
    out = subprocess.run(['powershell', '-NoProfile', '-File', r'qa\harness\stop.ps1', '-Profile', prof], capture_output=True, text=True)
    print(now(), out.stdout.strip(), out.stderr.strip()[:200])
    print('KILLED', prof)
    sys.exit(0)
print('NO-CLAIM')
