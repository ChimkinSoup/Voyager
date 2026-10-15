"""MD-11: attach a distinct test image to one parent on one profile, through
MediaService.attachBytes (the call the paste / drop / picker hooks end in).

    python qa/steps/md11-attach.py <qa|qb> <collection> <documentId> <label> [--facet front|back|gallery] [--file png] [--same]

The image is a small PNG drawn from <label> (its colour and text), so each label
gives different bytes; --file sends that file's bytes instead (same file on both
devices = same bytes, for the dedupe case). Prints the reference id, media id,
the asset's upload state right after the attach, and the device clock (epoch ms)
when the attach returned.
"""
import argparse, glob, hashlib, io, os, re, subprocess, time

from PIL import Image, ImageDraw

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VM = os.path.join(REPO, 'qa', 'logs', 'vm.exe')
LIB = 'core/media/widgets/media_attach.dart'
WALK = ("Element? e; void v(Element x) { if (e != null) return; if (x.widget.runtimeType.toString().startsWith('MaterialApp')) { e = x; } "
        "else { x.visitChildren(v); } } WidgetsBinding.instance.rootElement!.visitChildren(v); final c = ProviderScope.containerOf(e!, listen: false);")


def label_png(label):
    h = hashlib.sha256(label.encode()).digest()
    img = Image.new('RGB', (160, 96), (h[0], h[1], h[2]))
    d = ImageDraw.Draw(img)
    d.rectangle([8, 8, 152, 88], outline=(255 - h[0], 255 - h[1], 255 - h[2]), width=4)
    d.text((18, 38), label, fill=(255, 255, 255))
    out = io.BytesIO(); img.save(out, 'PNG')
    return out.getvalue()


def run_log(prof):
    return max(glob.glob(os.path.join(REPO, 'qa', 'logs', f'run-{prof}-*.exe.log')), key=os.path.getmtime)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('prof'); ap.add_argument('collection'); ap.add_argument('doc'); ap.add_argument('label')
    ap.add_argument('--facet', default='gallery'); ap.add_argument('--file')
    a = ap.parse_args()
    data = open(a.file, 'rb').read() if a.file else label_png(a.label)
    tag = f'md11att-{a.prof}-{int(time.time() * 1000)}'
    body = (f"final b = Uint8List.fromList([{','.join(str(x) for x in data)}]); "
            f"final m = c.read(mediaServiceProvider); "
            f"final rf = await m.attachBytes(bytes: b, collection: '{a.collection}', documentId: '{a.doc}', facet: MediaFacet.{a.facet}); "
            f"final at = await m.asset(rf.mediaId); "
            f"debugPrint('MD11ATT {tag} ' + rf.id + ' ' + rf.mediaId + ' ' + (at?.uploadState.name ?? '-') + ' ' + DateTime.now().millisecondsSinceEpoch.toString());")
    expr = f"Future(() async {{ try {{ {WALK} {body} debugPrint('SEED-OK {tag}'); }} catch (err) {{ debugPrint('SEED-ERR {tag} ' + err.toString()); }} }})"
    log = run_log(a.prof); off = os.path.getsize(log)
    r = subprocess.run([VM, 'eval', LIB, expr], cwd=REPO, env=dict(os.environ, VOYAGER_QA_PROFILE=a.prof),
                       capture_output=True, text=True, encoding='utf-8', errors='replace')
    if r.returncode != 0:
        print('EVAL FAILED', r.stderr[:800]); raise SystemExit(1)
    end = time.time() + 60
    while time.time() < end:
        with open(log, 'rb') as f:
            f.seek(off); new = f.read().decode('utf-8', 'replace')
        m = re.search(rf'MD11ATT {re.escape(tag)} (\S+) (\S+) (\S+) (\d+)', new)
        e = re.search(rf'SEED-ERR {re.escape(tag)}(.*)', new)
        if m:
            print(f'MD11ATT {a.prof} {a.collection}/{a.doc} ref={m.group(1)} media={m.group(2)} upload={m.group(3)} mark={m.group(4)} bytes={len(data)}')
            return
        if e:
            print('SEED-ERR', e.group(1)[:400]); raise SystemExit(1)
        time.sleep(0.1)
    print('TIMEOUT'); raise SystemExit(1)


if __name__ == '__main__':
    main()
