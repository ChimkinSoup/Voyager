# Phase 28B (app stopped): corrupt <id>[.thumb] files (flip 20 bytes at 40),
# or move a full file aside / back.  p28b-blobfx.py corrupt <name>... | hide <id> | unhide <id>
import os, shutil, sys
D = os.path.expandvars(r'%APPDATA%\Voyager\voyager-profile-qa\vault_media')
BAK = os.path.expandvars(r'%LOCALAPPDATA%\Temp\claude\p28b-hidden')
os.makedirs(BAK, exist_ok=True)
op = sys.argv[1]
for n in sys.argv[2:]:
    p = os.path.join(D, n)
    if op == 'corrupt':
        b = bytearray(open(p, 'rb').read())
        for i in range(40, 60):
            b[i] ^= 0xFF
        open(p, 'wb').write(b)
        print('corrupted', n, len(b))
    elif op == 'hide':
        shutil.move(p, os.path.join(BAK, n)); print('hidden', n)
    elif op == 'unhide':
        shutil.move(os.path.join(BAK, n), p); print('restored', n)
print('files', len(os.listdir(D)))
