"""O7 summary of qa/exports/md2-latency.tsv: per feature (tag prefix) and direction,
median / max of db_ms and ui_ms (ms from the writer's save). Skips failed or
malformed rows and the bulk seeds.

    python qa/steps/md2lat.py
"""
import collections, os, re, statistics as st

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
g = collections.defaultdict(lambda: {'db': [], 'ui': []})
for line in open(os.path.join(REPO, 'qa', 'exports', 'md2-latency.tsv'), encoding='utf-8'):
    r = line.rstrip('\n').split('\t')
    if len(r) < 7 or not r[0] == 'MD2' or not r[4].startswith('OK'):
        continue
    tag = r[2].split('#')[0]
    if 'seed' in tag or 'probe' in tag:
        continue
    key = (tag.split('-')[0], r[3])
    m = re.search(r'db_ms=(\d+)', r[5]); u = re.search(r'ui_ms=(\d+)', r[6])
    if m and int(m.group(1)) > 0: g[key]['db'].append(int(m.group(1)))
    if u: g[key]['ui'].append(int(u.group(1)))
print('feature\tdir\tn\tdb_med\tdb_max\tui_n\tui_med\tui_max')
for (f, d), v in sorted(g.items()):
    db, ui = v['db'], v['ui']
    print(f"{f}\t{d}\t{len(db)}\t{st.median(db) if db else '-'}\t{max(db) if db else '-'}\t{len(ui)}\t{st.median(ui) if ui else '-'}\t{max(ui) if ui else '-'}")
alldb = [x for v in g.values() for x in v['db']]; allui = [x for v in g.values() for x in v['ui']]
print(f'ALL\tdb n={len(alldb)} med={st.median(alldb)} max={max(alldb)}\tui n={len(allui)} med={st.median(allui)} max={max(allui)}')
