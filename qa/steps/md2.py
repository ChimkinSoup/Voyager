"""MD-2 driver: run a write on one profile, time its arrival on the other.

    python qa/steps/md2.py <writer qa|qb> <tag> <lib> <bodyfile> --sql "<receiver sql>"
           [--find "text"] [--absent] [--timeout 60] [--note "..."]

The body is an evalc-style Dart body (c = the app's ProviderContainer).
Placeholders: @TAG@ -> tag, @W@ -> writer profile, @N@ -> --n (run number). `MARK;` -> a debugPrint of
the writer's clock (epoch ms) at that point: put it right after the local save.
Receiver = the other profile. The receiver SQL (read-only, same placeholders)
must return a row once the change has landed there. --find waits for a
hit-testable on-screen text on the receiver (vm.exe find), --absent for it to
go away (env MD2_ANYTEXT=1: any Text in the widget tree, incl. not hit-testable). Prints one MD2 line and appends it to qa/exports/md2-latency.tsv:
db_ms / ui_ms are measured from the writer's MARK.
"""
import argparse, glob, os, re, sqlite3, subprocess, threading, time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VM = os.path.join(REPO, 'qa', 'logs', 'vm.exe')
WALK = ("Element? e; void v(Element x) { if (e != null) return; if (x.widget.runtimeType.toString().startsWith('MaterialApp')) { e = x; } "
        "else { x.visitChildren(v); } } WidgetsBinding.instance.rootElement!.visitChildren(v); final c = ProviderScope.containerOf(e!, listen: false);")


def run_log(prof):
    logs = glob.glob(os.path.join(REPO, 'qa', 'logs', f'run-{prof}-*.exe.log'))
    return max(logs, key=os.path.getmtime)


def vm(prof, *args):
    env = dict(os.environ, VOYAGER_QA_PROFILE=prof)
    return subprocess.run([VM, *args], cwd=REPO, env=env, capture_output=True, text=True, encoding='utf-8', errors='replace')


def db_uri(prof):
    p = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{prof}', 'voyager.sqlite')
    return 'file:' + p.replace('\\', '/') + '?mode=ro'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('writer'); ap.add_argument('tag'); ap.add_argument('lib'); ap.add_argument('body')
    ap.add_argument('--sql', required=True); ap.add_argument('--find'); ap.add_argument('--absent', action='store_true')
    ap.add_argument('--timeout', type=float, default=60); ap.add_argument('--n', default='1'); ap.add_argument('--note', default='')
    a = ap.parse_args()
    recv = 'qb' if a.writer == 'qa' else 'qa'
    sub = lambda s: s.replace('@TAG@', a.tag).replace('@W@', a.writer).replace('@N@', a.n)
    body = sub(open(a.body, encoding='ascii').read())
    body = body.replace('MARK;', f"debugPrint('MD2T {a.tag} ' + DateTime.now().millisecondsSinceEpoch.toString());")
    body = re.sub(r'\r?\n', ' ', body)
    sql = sub(a.sql)
    expr = f"Future(() async {{ try {{ {WALK} {body} debugPrint('SEED-OK {a.tag}'); }} catch (err) {{ debugPrint('SEED-ERR {a.tag} ' + err.toString()); }} }})"

    log = run_log(a.writer)
    off = os.path.getsize(log)
    hit = {}

    def poll():
        end = time.time() + a.timeout + 30
        while time.time() < end and 'db' not in hit:
            try:
                con = sqlite3.connect(db_uri(recv), uri=True, timeout=5)
                row = con.execute(sql).fetchone(); con.close()
                if row is not None:
                    hit['db'] = time.time(); hit['row'] = row; return
            except sqlite3.OperationalError:
                pass
            time.sleep(0.25)

    th = threading.Thread(target=poll); th.start()
    r = vm(a.writer, 'eval', a.lib, expr)
    if r.returncode != 0:
        print('EVAL FAILED', r.stdout[-300:], r.stderr[:1200]); hit['db'] = 0; th.join(); return
    stamp = None; status = None
    end = time.time() + 40
    while time.time() < end and status is None:
        with open(log, 'rb') as f:
            f.seek(off); new = f.read().decode('utf-8', 'replace')
        m = re.search(rf'MD2T {re.escape(a.tag)} (\d+)', new)
        if m: stamp = int(m.group(1)) / 1000
        m2 = re.search(rf'SEED-(OK|ERR) {re.escape(a.tag)}(.*)', new)
        if m2: status = (m2.group(1) + m2.group(2)[:300]).strip()
        time.sleep(0.2)
    th.join(a.timeout + 31)
    db_ms = round((hit['db'] - stamp) * 1000) if stamp and 'db' in hit else None
    ui_ms = None; ui_state = '-'
    if a.find and 'db' in hit:
        end = time.time() + 30
        while time.time() < end:
            if os.environ.get('MD2_ANYTEXT'):  # any Text in the tree, hit-testable or not (locate's similar list)
                rr = vm(recv, 'locate', '1', a.find)
                labels = [l for l in (rr.stdout + rr.stderr).splitlines() if l.startswith(('text\t', 'tip\t', 'key\t'))]
                out = a.find if rr.returncode == 0 else '\n'.join(labels)  # exit 0 = an exact clickable match
            else:
                out = vm(recv, 'find', a.find).stdout
            present = a.find.lower() in out.lower()
            if present != a.absent:
                ui_ms = round((time.time() - stamp) * 1000) if stamp else None; ui_state = 'gone' if a.absent else 'shown'; break
            time.sleep(0.4)
        else:
            ui_state = 'STILL-THERE' if a.absent else 'NOT-SHOWN'
    line = f"MD2\t{time.strftime('%H:%M:%S')}\t{a.tag}#{a.n}\t{a.writer}->{recv}\t{status}\tdb_ms={db_ms}\tui={ui_state} ui_ms={ui_ms}\trow={hit.get('row')}\t{a.note}"
    print(line)
    with open(os.path.join(REPO, 'qa', 'exports', 'md2-latency.tsv'), 'a', encoding='utf-8') as f:
        f.write(line + '\n')


if __name__ == '__main__':
    main()
