"""MD-17.1 soak: alternating two-way writes on every page for N minutes, with Force-offline windows.

    python qa/steps/md17-soak.py [--minutes 60] [--offline-every 10] [--hold 100] [--start-round 0]

Each round: the writer (A on even rounds, B on odd) types a journal entry through the real UI
(voy.ps1, bg), timed to the receiver's row and screen; then both open the round's feature page and
the writer runs that feature's MD-2 spec (create / edit / delete, md2.py: timed to the receiver's
row and, where the page shows it, its screen). Run ids: md2-*-<writer>k<round>.
Every --offline-every minutes one device (A, B, A, ...) goes Force offline for --hold s: meanwhile
both write blind (no receiver wait: create/edit/delete of two plain features each, plus a typed
entry each); after reconnecting, the catch-up time until every one of those records is on the
other device is measured. md2.py's rows go to qa/exports/md17-latency.tsv (moved out of
md2-latency.tsv); the round log is qa/exports/md17-soak.log.
"""
import argparse, os, re, sqlite3, subprocess, sys, threading, time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STEPS = os.path.join(REPO, 'qa', 'steps')
sys.path.insert(0, STEPS)
import md2  # noqa: E402  (vm, run_log, db_uri, WALK)

VOY = os.path.join(REPO, 'qa', 'harness', 'voy.ps1')
EXP = os.path.join(REPO, 'qa', 'exports')
LOG = os.path.join(EXP, 'md17-soak.log')
DEV = 'features/dev/dev_page.dart'

# (spec, rail label or None, find on receiver?, MD2_ANYTEXT, below the rail fold)
FEATURES = [
    ('md02-dreams.tsv', 'Dreams', True, False, False),
    ('md02-todo.tsv', 'To-Do', True, False, False),
    ('md02-calendar.tsv', 'Calendar', True, False, False),
    ('md02-trackers.tsv', 'Analytics', True, True, False),
    ('md02-finance.tsv', 'Finance', True, False, False),
    ('md02-journal.tsv', 'Journal', True, False, False),
    ('md02-leetcode.tsv', 'LeetCode', True, False, False),
    ('md02-rankings.tsv', 'Rankings', True, False, False),
    ('md02-jobs.tsv', 'Jobs', True, False, False),
    ('md02-study.tsv', 'Study', True, False, True),
    ('md02-workout.tsv', 'Workout', True, False, True),
    ('md02-todox.tsv', 'To-Do', True, False, False),
    ('md02-life.tsv', 'Life', False, False, False),
    ('md02-inbox.tsv', None, False, False, False),
    ('md02-reminders.tsv', None, False, False, False),
    ('md02-text.tsv', None, False, False, False),
    ('md02-text2.tsv', None, False, False, False),
    ('md02-jobsx.tsv', 'Jobs', True, True, False),
]
# plain create/edit/delete specs used blind in the offline windows (own ids, no shared records)
BLIND = ['md02-dreams.tsv', 'md02-todo.tsv', 'md02-calendar.tsv', 'md02-finance.tsv', 'md02-leetcode.tsv',
         'md02-life.tsv', 'md02-study.tsv', 'md02-rankings.tsv', 'md02-trackers.tsv', 'md02-workout.tsv']


def log(msg):
    line = f"{time.strftime('%H:%M:%S')} {msg}"
    print(line, flush=True)
    with open(LOG, 'a', encoding='utf-8') as f:
        f.write(line + '\n')


def other(p):
    return 'qb' if p == 'qa' else 'qa'


def voy(prof, steps):
    r = subprocess.run(['powershell', '-NoProfile', '-Command', f'& "{VOY}" -Profile {prof} do "{steps}"'],
                       cwd=REPO, capture_output=True, text=True, encoding='utf-8', errors='replace')
    out = (r.stdout + r.stderr).strip()
    if 'FAIL' in out or 'not found' in out.lower() or 'refus' in out.lower():
        log(f'VOY {prof} PROBLEM: {out[-300:]}')
    return out


def goto(prof, label, below):
    if label is None:
        return
    if below:
        voy(prof, f'wheel 88 1300 -10; wait 1300; tap {label}; wait 1500')
    else:
        voy(prof, f'wheel 88 900 10; wait 500; tap {label}; wait 1500')


def letters(k):
    return ''.join('abcdefghij'[int(d)] for d in str(k))


def q1(prof, sql):
    try:
        con = sqlite3.connect(md2.db_uri(prof), uri=True, timeout=5)
        row = con.execute(sql).fetchone(); con.close()
        return row
    except sqlite3.OperationalError:
        return None


def wait_sql(prof, sql, timeout):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if q1(prof, sql) is not None:
            return time.time() - t0
        time.sleep(0.25)
    return None


def find_ui(prof, text, timeout=30):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if text.lower() in md2.vm(prof, 'find', text).stdout.lower():
            return time.time() - t0
        time.sleep(0.4)
    return None


def spec_lines(spec):
    lines = [l.rstrip('\n') for l in open(os.path.join(STEPS, spec), encoding='utf-8') if l.strip() and not l.startswith('#')]
    return lines[0].split('\t')[1], [l.split('\t') for l in lines[1:]]


def typed_entry(w, k, measure=True):
    """Real UI: New entry on the writer's Journal page, type a title and a body; time it on the receiver."""
    title = f'mdsoak {letters(k)} {w}'
    goto(w, 'Journal', False)
    sql = f"select id from journal_entries_table where title = '{title}' and body like 'soak body%{w}%' and deleted_at is null"
    rcv = other(w)
    th = threading.Thread(target=voy, args=(w, f'click 488 1736; wait 900; click 1843 137; wait 300; type {title}; wait 400; click 1843 1008; wait 300; type soak body {letters(k)} from {w}; wait 2500'))
    th.start()
    if not measure:
        th.join()
        return title, sql, q1(w, sql) is not None
    tw = tr = None; end = time.time() + 90
    while time.time() < end and tr is None:  # writer's saved row (title + body), then the receiver's
        if tw is None and q1(w, sql) is not None:
            tw = time.time()
        if q1(rcv, sql) is not None:
            tr = time.time()
        time.sleep(0.25)
    th.join()
    own = q1(w, sql)
    dt = (tr - tw) if tr and tw else None
    ui = None
    if dt is not None and find_ui(rcv, title) is not None:
        ui = time.time() - tw
    # both measured from the writer's saved row (title + body) to the receiver's row / screen
    log(f"TYPED {w}->{rcv} '{title}' own={'yes' if own else 'NO'} db_s={None if dt is None else round(dt, 2)} ui_s={None if ui is None else round(ui, 2)}")
    return title, sql, own is not None


def run_spec(w, k, spec, find, anytext):
    lib, acts = spec_lines(spec)
    n = f'k{k}'
    for tag, body, sql, ftext, absent, note in acts:
        args = [sys.executable, os.path.join(STEPS, 'md2.py'), w, tag, lib, os.path.join(STEPS, body), '--sql', sql, '--n', n,
                '--note', f'MD17 {note}', '--timeout', '60']
        if find and ftext != '-':
            args += ['--find', ftext.replace('@W@', w).replace('@N@', n)]
            if absent == '1':
                args.append('--absent')
        env = dict(os.environ)
        if anytext:
            env['MD2_ANYTEXT'] = '1'
        out = subprocess.run(args, cwd=REPO, capture_output=True, text=True, env=env).stdout.strip()
        log('  ' + out.replace('\t', ' | ')[:400])
        if 'EVAL FAILED' in out or 'db_ms=None' in out or '\tERR' in out:
            log(f'  !! {spec} {tag} on {w} round {k} failed; continuing with the next feature')
            return False
    return True


def eval_body(prof, lib, bodyfile, tag, extra=None):
    body = open(os.path.join(STEPS, bodyfile), encoding='ascii').read()
    for a_, b_ in (extra or {}).items():
        body = body.replace(a_, b_)
    body = body.replace('MARK;', f"debugPrint('MD2T {tag} ' + DateTime.now().millisecondsSinceEpoch.toString());")
    body = re.sub(r'\r?\n', ' ', body)
    expr = f"Future(() async {{ try {{ {md2.WALK} {body} debugPrint('SEED-OK {tag}'); }} catch (err) {{ debugPrint('SEED-ERR {tag} ' + err.toString()); }} }})"
    lg = md2.run_log(prof); off = os.path.getsize(lg)
    r = md2.vm(prof, 'eval', lib, expr)
    if r.returncode != 0:
        log(f'EVAL FAILED {prof} {tag}: {r.stderr[:300]}')
        return False
    end = time.time() + 30
    while time.time() < end:  # wait for the local save (MARK) or the end of a mark-less body
        with open(lg, 'rb') as f:
            f.seek(off); new = f.read().decode('utf-8', 'replace')
        if f'MD2T {tag} ' in new or f'SEED-OK {tag}' in new:
            return True
        if f'SEED-ERR {tag}' in new:
            log(f'SEED-ERR {prof} {tag}: ' + new[new.index(f'SEED-ERR {tag}'):][:300])
            return False
        time.sleep(0.2)
    log(f'NO MARK {prof} {tag} within 30 s')
    return False


def blind_spec(w, n, spec):
    lib, acts = spec_lines(spec)
    last_sql = None
    for tag, body, sql, *_ in acts:
        ok = eval_body(w, lib, body, f'{tag}-{w}{n}', {'@W@': w, '@N@': n, '@TAG@': tag})
        last_sql = sql.replace('@W@', w).replace('@N@', n)
        if not ok:
            return None
    return last_sql


def offline_window(dev, k, hold, wn):
    on = other(dev)
    log(f'OFFLINE window {wn}: {dev} goes offline for {hold} s (round {k})')
    eval_body(dev, DEV, 'md11-resumed.dart.txt', f'res{wn}{dev}')
    eval_body(dev, DEV, 'md-offline-on.dart.txt', f'off{wn}{dev}')
    t_off = time.time()
    pend = []  # (receiver, sql, label)
    for i, w in enumerate((dev, on, dev, on)):
        spec = BLIND[(wn * 4 + i) % len(BLIND)]
        n = f'w{letters(wn)}{i}'
        sql = blind_spec(w, n, spec)
        log(f'  blind {spec} on {w} n={n}: {"saved" if sql else "FAILED"}')
        if sql:
            pend.append((other(w), sql, f'{spec}@{w}{n}'))
    for w in (dev, on):
        title, sql, own = typed_entry(w, 800 + wn * 10 + (0 if w == 'qa' else 1), measure=False)
        log(f"  blind typed '{title}' on {w}: own row {'yes' if own else 'NO'}")
        pend.append((other(w), sql, f'typed@{w}'))
    rest = hold - (time.time() - t_off)
    if rest > 0:
        time.sleep(rest)
    log(f'  outbox during hold: {outbox()}')
    eval_body(dev, DEV, 'md-offline-off.dart.txt', f'on{wn}{dev}')
    t_on = time.time()
    worst = 0; missing = []
    for rcv, sql, label in pend:
        left = 240 - (time.time() - t_on)
        dt = wait_sql(rcv, sql, max(left, 1))
        if dt is None:
            missing.append(f'{label}->{rcv}')
        else:
            worst = max(worst, time.time() - t_on)
    log(f'OFFLINE window {wn} done: {len(pend) - len(missing)}/{len(pend)} arrived, all by {round(worst, 1)} s after reconnect; missing {missing}; outbox {outbox()}')


def outbox():
    return ' '.join(f"{p}={(q1(p, 'select count(*) from pending_uploads_table') or ['?'])[0]}" for p in ('qa', 'qb'))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--minutes', type=float, default=60); ap.add_argument('--offline-every', type=float, default=10)
    ap.add_argument('--hold', type=float, default=100); ap.add_argument('--start-round', type=int, default=0)
    a = ap.parse_args()
    lat = os.path.join(EXP, 'md2-latency.tsv')
    base = open(lat, encoding='utf-8').read()
    t0 = time.time(); k = a.start_round; wn = 0
    log(f'SOAK START minutes={a.minutes} offline_every={a.offline_every} hold={a.hold} outbox {outbox()}')
    try:
        while time.time() - t0 < a.minutes * 60:
            if time.time() - t0 >= (wn + 1) * a.offline_every * 60 and (wn + 1) * a.offline_every < a.minutes:
                offline_window('qa' if wn % 2 == 0 else 'qb', k, a.hold, wn)
                wn += 1
                continue
            w = 'qa' if k % 2 == 0 else 'qb'
            spec, label, find, anytext, below = FEATURES[(k // 2) % len(FEATURES)]
            log(f'ROUND {k} writer {w} feature {spec} (t+{round((time.time() - t0) / 60, 1)} min) outbox {outbox()}')
            typed_entry(w, k)
            goto('qa', label, below); goto('qb', label, below)
            run_spec(w, k, spec, find, anytext)
            if below:  # bring the rail back to the top
                voy('qa', 'wheel 88 900 10; wait 400'); voy('qb', 'wheel 88 900 10; wait 400')
            k += 1
    finally:
        now = open(lat, encoding='utf-8').read()
        new = now[len(base):] if now.startswith(base) else ''
        if new:
            with open(os.path.join(EXP, 'md17-latency.tsv'), 'a', encoding='utf-8') as f:
                f.write(new)
            with open(lat, 'w', encoding='utf-8') as f:
                f.write(base)
        log(f'SOAK END rounds {a.start_round}..{k - 1} windows {wn} elapsed {round((time.time() - t0) / 60, 1)} min outbox {outbox()}')


if __name__ == '__main__':
    main()
