# Phase 20: run clipboard fixtures through the app's own parseJobClipboard over the VM service.
# Usage: python qa/steps/p20-parse.py <path to vm.exe>   (from the repo root)
import subprocess, sys
sys.stdout.reconfigure(encoding='utf-8')
vm = sys.argv[1]
fixtures = [
    'https://example.com/job/1',
    'boards.greenhouse.io/acme/jobs/1',
    'Software Engineer https://example.com/x',
    'https://example.com/x Software Engineer',
    'Software Engineer\nhttps://example.com/x',
    'Software Engineer\r\nhttps://example.com/x',
    'Senior Engineer (Backend) https://example.com/x',
    '[Backend Eng](https://example.com/x)',
    'Just a title',
    'name@acme.com',
    'Eng https://a.com/1 https://b.com/2',
    'https://Software Engineer en.wikipedia.org/wiki/Shark',
    'https://www.Data Engineer Intern coinbase.com/en-ca/careers/positions/8175459',
    'Node.js Developer',
    'See https://example.com/x.',
    '(https://example.com/x)',
    '"Quoted Title https://example.com/q"',
    '<https://example.com/angle>',
    'C++ Engineer e.g v2.0',
    'ftp://example.com/file Dev',
    'file:///C:/secret.txt',
    'javascript:alert(1)',
    'https://',
    '   ',
    'Caf\u00e9 \u6771\u4eac \U0001F600 https://example.com/intl',
    'Dev\thttps://example.com/tab',
    'HTTPS://EXAMPLE.COM/UP Dev',
    'Dev http://localhost:8080/x',
    'Dev 192.168.0.1/jobs',
    'Dev example.com/a?b=c&utm_source=x#frag',
    'JD ' + 'word ' * 2000 + 'https://example.com/late',
    'x' * 10000,
    'T https://example.com/' + 'p' * 600,
]
for f in fixtures:
    codes = ','.join(str(ord(c)) for c in f) if len(f) < 700 else None
    if codes is None:
        # long fixtures: build in Dart to keep the expression short
        if f.startswith('JD '):
            src = "'JD ' + ('word ' * 2000) + 'https://example.com/late'"
        elif f.startswith('T '):
            src = "'T https://example.com/' + ('p' * 600)"
        else:
            src = "'x' * 10000"
    else:
        src = 'String.fromCharCodes([' + codes + '])'
    expr = "((r) => 'T=' + (r.title == null ? 'null' : '[' + (r.title!.length > 60 ? r.title!.substring(0, 60) + '..(' + r.title!.length.toString() + ')' : r.title!) + ']') + ' U=' + (r.url == null ? 'null' : (r.url!.length > 50 ? r.url!.substring(0, 50) + '..(' + r.url!.length.toString() + ')' : r.url!)))(parseJobClipboard(" + src + "))"
    out = subprocess.run([vm, 'eval', 'features/jobs/job_clipboard_parser.dart', expr], capture_output=True, text=True, encoding='utf-8')
    print(repr(f[:70]), '->', (out.stdout or out.stderr).strip())
