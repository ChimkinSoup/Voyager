"""Navigate both profiles to a rail page, then run a spec A->B (n) and B->A (n+1).

    python qa/steps/md2page.py <RailLabel> <spec.tsv> <n>
"""
import os, subprocess, sys
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
label, spec, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
voy = os.path.join(REPO, 'qa', 'harness', 'voy.ps1')
for p in ('qa', 'qb'):
    r = subprocess.run(['powershell', '-NoProfile', '-Command', f'& "{voy}" -Profile {p} do "tap {label}; wait 1500"'], cwd=REPO, capture_output=True, text=True)
    print(p, (r.stdout + r.stderr).strip()[:200])
for w, k in (('qa', n), ('qb', n + 1)):
    r = subprocess.run([sys.executable, os.path.join(REPO, 'qa', 'steps', 'md2cycle.py'), spec, w, str(k)], cwd=REPO, capture_output=True, text=True)
    print(r.stdout.strip())
