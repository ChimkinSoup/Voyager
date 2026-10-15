"""Run an MD-2 spec through md2.py, one action after another.

    python qa/steps/md2cycle.py <spec.tsv> <writer qa|qb> <n> [first_tag]

Spec: first line `lib<TAB><libSuffix>`; then one action per line:
    tag<TAB>bodyfile<TAB>receiver sql<TAB>find text (or -)<TAB>absent 0|1<TAB>note
'#' lines are skipped. Placeholders as in md2.py (@W@, @N@). first_tag starts
the run at that action (to resume after a failure).
"""
import os, subprocess, sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
spec, writer, n = sys.argv[1], sys.argv[2], sys.argv[3]
start = sys.argv[4] if len(sys.argv) > 4 else None
lines = [l.rstrip('\n') for l in open(spec, encoding='utf-8') if l.strip() and not l.startswith('#')]
lib = lines[0].split('\t')[1]
started = start is None
for l in lines[1:]:
    tag, body, sql, find, absent, note = l.split('\t')
    if not started:
        if tag != start:
            continue
        started = True
    args = [sys.executable, os.path.join(REPO, 'qa', 'steps', 'md2.py'), writer, tag, lib, os.path.join(REPO, 'qa', 'steps', body), '--sql', sql, '--n', n, '--note', note]
    if find != '-':
        args += ['--find', find.replace('@W@', writer).replace('@N@', n)]
    if absent == '1':
        args.append('--absent')
    out = subprocess.run(args, cwd=REPO, capture_output=True, text=True).stdout.strip()
    print(out)
    if 'EVAL FAILED' in out or '\tNone\t' in out or '\tERR ' in out:
        print('STOPPED at', tag)
        break
