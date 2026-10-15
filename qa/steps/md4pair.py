"""MD-4 driver: run one evalc-style body on A (qa) and one on B (qb) at the same time.

    python qa/steps/md4pair.py <lib> <bodyA> [<bodyB>] [--delay-ms N] [--tag t] [--only qa|qb]

With one body, the same file runs on both, with @W@ -> qa / qb (so a body can
branch: `if ('@W@' == 'qa') ... else ...`). B starts --delay-ms after A
(default 0: both eval calls are sent in parallel threads, so neither device has
the other's change yet); a negative value delays A instead. `MARK;` in a body logs the device's clock (epoch ms)
at that point: put it right after the local save. Prints each side's status
and MARK, and which saved later.
"""
import argparse, glob, os, re, subprocess, threading, time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VM = os.path.join(REPO, 'qa', 'logs', 'vm.exe')
WALK = ("Element? e; void v(Element x) { if (e != null) return; if (x.widget.runtimeType.toString().startsWith('MaterialApp')) { e = x; } "
        "else { x.visitChildren(v); } } WidgetsBinding.instance.rootElement!.visitChildren(v); final c = ProviderScope.containerOf(e!, listen: false);")


def run_log(prof):
    return max(glob.glob(os.path.join(REPO, 'qa', 'logs', f'run-{prof}-*.exe.log')), key=os.path.getmtime)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('lib'); ap.add_argument('body_a'); ap.add_argument('body_b', nargs='?')
    ap.add_argument('--delay-ms', type=int, default=0); ap.add_argument('--tag', default='md4')
    ap.add_argument('--only')
    a = ap.parse_args()
    profs = [a.only] if a.only else ['qa', 'qb']
    res = {}

    def run(prof, delay):
        path = a.body_b if (prof == 'qb' and a.body_b) else a.body_a
        body = open(path, encoding='ascii').read().replace('@W@', prof).replace('@TAG@', a.tag)
        tag = f'{a.tag}-{prof}'
        body = body.replace('MARK;', f"debugPrint('MD4T {tag} ' + DateTime.now().millisecondsSinceEpoch.toString());")
        body = re.sub(r'\r?\n', ' ', body)
        expr = f"Future(() async {{ try {{ {WALK} {body} debugPrint('SEED-OK {tag}'); }} catch (err) {{ debugPrint('SEED-ERR {tag} ' + err.toString()); }} }})"
        log = run_log(prof); off = os.path.getsize(log)
        time.sleep(delay / 1000)
        r = subprocess.run([VM, 'eval', a.lib, expr], cwd=REPO, env=dict(os.environ, VOYAGER_QA_PROFILE=prof),
                           capture_output=True, text=True, encoding='utf-8', errors='replace')
        if r.returncode != 0:
            res[prof] = ('EVAL FAILED ' + r.stderr[:800], None); return
        stamp = status = None; end = time.time() + 60
        while time.time() < end and status is None:
            with open(log, 'rb') as f:
                f.seek(off); new = f.read().decode('utf-8', 'replace')
            m = re.search(rf'MD4T {re.escape(tag)} (\d+)', new)
            if m: stamp = int(m.group(1))
            m2 = re.search(rf'SEED-(OK|ERR) {re.escape(tag)}(.*)', new)
            if m2: status = (m2.group(1) + m2.group(2)[:300]).strip()
            time.sleep(0.1)
        res[prof] = (status, stamp)

    # A negative --delay-ms delays A instead (A saves later).
    ths = [threading.Thread(target=run, args=(p, max(0, -a.delay_ms) if p == 'qa' else max(0, a.delay_ms))) for p in profs]
    for t in ths: t.start()
    for t in ths: t.join()
    for p in profs:
        print(f'MD4PAIR {a.tag} {p}: {res[p][0]} mark={res[p][1]}')
    if len(profs) == 2 and res['qa'][1] and res['qb'][1]:
        d = res['qb'][1] - res['qa'][1]
        print(f'MD4PAIR {a.tag} B-A save gap {d} ms ({"B" if d > 0 else "A"} saved later)')


if __name__ == '__main__':
    main()
