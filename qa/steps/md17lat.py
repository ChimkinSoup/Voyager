"""MD-17.2: O7 summary of the soak (qa/exports/md17-latency.tsv + the TYPED lines of md17-soak.log after the
last "restart 2" marker): per feature and direction, n / median / worst of db and on-screen latency, the
UI outcome counts, and any action over 5 s. Trial rows (run k1000+) are skipped.

    python qa/steps/md17lat.py
"""
import collections, os, re, statistics as st

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
g = collections.defaultdict(lambda: {'db': [], 'ui': [], 'uist': collections.Counter()})
slow = []
for line in open(os.path.join(REPO, 'qa', 'exports', 'md17-latency.tsv'), encoding='utf-8'):
    r = line.rstrip('\n').split('\t')
    if len(r) < 7 or r[0] != 'MD2':
        continue
    tag, n = r[2].split('#')
    if re.fullmatch(r'k1\d{3}', n):
        continue
    key = (tag.split('-')[0], r[3])
    m = re.search(r'db_ms=(\d+)', r[5]); u = re.search(r'ui_ms=(\d+)', r[6]); s = re.search(r'ui=(\S+)', r[6])
    if m: g[key]['db'].append(int(m.group(1)))
    if u: g[key]['ui'].append(int(u.group(1)))
    g[key]['uist'][s.group(1) if s else '?'] += 1
    for v, what in ((m, 'db'), (u, 'ui')):
        if v and int(v.group(1)) > 5000:
            slow.append(f'{r[1]} {r[2]} {r[3]} {what}={v.group(1)}')
log = open(os.path.join(REPO, 'qa', 'exports', 'md17-soak.log'), encoding='utf-8').read()
log = log[log.rfind('restart 2'):]
for m in re.finditer(r"TYPED (\w+->\w+) '[^']*' own=(\w+) db_s=([\d.]+|None) ui_s=([\d.]+|None)", log):
    key = ('typed', m.group(1))
    if m.group(3) != 'None': g[key]['db'].append(round(float(m.group(3)) * 1000))
    if m.group(4) != 'None': g[key]['ui'].append(round(float(m.group(4)) * 1000))
    g[key]['uist']['shown' if m.group(4) != 'None' else ('own=NO' if m.group(2) == 'NO' else 'NOT-SHOWN')] += 1
print('feature\tdir\tn\tdb_med\tdb_max\tui_n\tui_med\tui_max\tui outcomes')
for (f, d), v in sorted(g.items()):
    db, ui = v['db'], v['ui']
    print(f"{f}\t{d}\t{len(db)}\t{st.median(db) if db else '-'}\t{max(db) if db else '-'}\t{len(ui)}\t{st.median(ui) if ui else '-'}\t{max(ui) if ui else '-'}\t{dict(v['uist'])}")
for d in ('qa->qb', 'qb->qa'):
    alldb = [x for (f, dd), v in g.items() if dd == d for x in v['db']]; allui = [x for (f, dd), v in g.items() if dd == d for x in v['ui']]
    print(f'ALL {d}\tdb n={len(alldb)} med={st.median(alldb)} max={max(alldb)}\tui n={len(allui)} med={st.median(allui)} max={max(allui)}')
print('over 5 s:', slow or 'none')
