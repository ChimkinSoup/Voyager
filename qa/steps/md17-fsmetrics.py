"""MD-17.4: Firestore document read / write / delete counts for the project from Cloud Monitoring.

    python qa/steps/md17-fsmetrics.py <start HH:MM> <end HH:MM> [--step 60]   (local times today)

Read-only (monitoring.timeSeries.list with the gcloud user's token). Project-wide: every client
of voyager-db9de counts, so make sure nothing else (Juno's install) runs in the window.
Prints per-minute sums and the totals per metric, split by the metric's labels.
"""
import argparse, collections, datetime as dt, json, subprocess, urllib.parse, urllib.request

PROJECT = 'voyager-db9de'
METRICS = ['firestore.googleapis.com/document/read_count', 'firestore.googleapis.com/document/write_count',
           'firestore.googleapis.com/document/delete_count', 'firestore.googleapis.com/network/active_connections',
           'firestore.googleapis.com/network/snapshot_listeners']

ap = argparse.ArgumentParser(); ap.add_argument('start'); ap.add_argument('end'); ap.add_argument('--step', type=int, default=60)
a = ap.parse_args()
tok = subprocess.run('gcloud auth print-access-token', shell=True, capture_output=True, text=True).stdout.strip()
today = dt.date.today()
def utc(hm):
    h, m = map(int, hm.split(':'))
    return dt.datetime.combine(today, dt.time(h, m)).astimezone(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
for metric in METRICS:
    gauge = 'network' in metric
    q = {'filter': f'metric.type="{metric}"', 'interval.startTime': utc(a.start), 'interval.endTime': utc(a.end),
         'aggregation.alignmentPeriod': f'{a.step}s', 'aggregation.perSeriesAligner': 'ALIGN_MAX' if gauge else 'ALIGN_SUM'}
    url = f'https://monitoring.googleapis.com/v3/projects/{PROJECT}/timeSeries?' + urllib.parse.urlencode(q)
    req = urllib.request.Request(url, headers={'Authorization': f'Bearer {tok}'})
    try:
        data = json.load(urllib.request.urlopen(req))
    except Exception as ex:
        print(metric, 'ERROR', ex); continue
    tot = collections.Counter(); per_min = collections.Counter()
    for s in data.get('timeSeries', []):
        lab = ','.join(f'{k}={v}' for k, v in sorted(s['metric'].get('labels', {}).items()))
        for p in s['points']:
            v = int(p['value'].get('int64Value', p['value'].get('doubleValue', 0)))
            t = p['interval']['endTime'][11:16]
            if gauge:
                tot[lab] = max(tot[lab], v); per_min[t] = max(per_min[t], v)
            else:
                tot[lab] += v; per_min[t] += v
    print(f'== {metric.split("/", 1)[1]} ({"max" if gauge else "sum"}) {a.start}-{a.end}: ' + (', '.join(f'{k or "-"}: {v}' for k, v in tot.items()) or 'no data'))
    if not gauge and per_min:
        print('   per minute (UTC end): ' + ' '.join(f'{t}={v}' for t, v in sorted(per_min.items())))
