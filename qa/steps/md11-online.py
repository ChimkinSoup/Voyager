"""Read-only: print each change of a profile's connectivity state (the app's own
isOnline, which drives the offline badge and the reconnect resume).

    python qa/steps/md11-online.py <qa|qb> <seconds> [interval_s]
"""
import os, subprocess, sys, time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VM = os.path.join(REPO, 'qa', 'logs', 'vm.exe')
EXPR = ("(() { Element? e; void v(Element x) { if (e != null) return; if (x.widget.runtimeType.toString().startsWith('MaterialApp')) { e = x; } "
        "else { x.visitChildren(v); } } WidgetsBinding.instance.rootElement!.visitChildren(v); "
        "return ProviderScope.containerOf(e!, listen: false).read(connectivityStatusProvider).isOnline.toString(); })()")
prof, secs = sys.argv[1], float(sys.argv[2])
step = float(sys.argv[3]) if len(sys.argv) > 3 else 3
t0 = time.time(); last = None
while time.time() - t0 < secs:
    r = subprocess.run([VM, 'eval', 'features/dev/dev_page.dart', EXPR], cwd=REPO, env=dict(os.environ, VOYAGER_QA_PROFILE=prof),
                       capture_output=True, text=True, encoding='utf-8', errors='replace')
    val = r.stdout.strip().split()[-1] if r.stdout.strip() else 'ERR'
    if val != last:
        print(f'{time.strftime("%H:%M:%S")} +{time.time() - t0:5.1f}s isOnline={val}', flush=True); last = val
    time.sleep(step)
