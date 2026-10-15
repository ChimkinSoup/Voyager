"""MD-17: run MD-2 specs blind (create / edit / delete) on one profile while it is Force offline, then reconnect
and report whether each spec's final state reached the other device.

    python qa/steps/md17-blindx.py <qa|qb> <n> <spec.tsv>... [--hold 75]
"""
import importlib.util, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('soak', os.path.join(HERE, 'md17-soak.py'))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
args = [x for x in sys.argv[1:] if not x.startswith('--')]
hold = float(next((x.split('=')[1] for x in sys.argv if x.startswith('--hold=')), 75))
w, n, specs = args[0], args[1], args[2:]
m.eval_body(w, m.DEV, 'md11-resumed.dart.txt', f'resx{n}')
m.eval_body(w, m.DEV, 'md-offline-on.dart.txt', f'offx{n}')
pend = []
for s in specs:
    pend.append((s, m.blind_spec(w, n, s)))
    m.log(f'blindx {s} on {w} n={n} saved')
time.sleep(hold)
m.log(f'blindx outbox during hold: {m.outbox()}')
m.eval_body(w, m.DEV, 'md-offline-off.dart.txt', f'onx{n}')
t0 = time.time()
for s, sql in pend:
    dt = m.wait_sql(m.other(w), sql, max(90 - (time.time() - t0), 1))
    m.log(f'blindx {s} {w}{n} -> {m.other(w)}: ' + ('arrived' if dt is not None else 'MISSING after 90 s'))
m.log(f'blindx outbox after: {m.outbox()}')
