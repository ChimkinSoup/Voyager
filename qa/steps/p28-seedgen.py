# Phase 28A: writes qa/data/p28/seed/s0..s9.jpg and the evalc body
# qa/steps/p28-seed.dart.txt (three series of bulk history through the app's
# own PhotoSeriesService, vault unlocked), and prints the expected dates.
# Run from the repo root.
import datetime as dt
import json
import os
from PIL import Image, ImageDraw, ImageFont

SEED = os.path.join('qa', 'data', 'p28', 'seed')
os.makedirs(SEED, exist_ok=True)
font = ImageFont.truetype('arialbd.ttf', 120)
for n in range(10):
    im = Image.new('RGB', (240, 320), (30 + n * 20, 80, 160 - n * 10))
    ImageDraw.Draw(im).text((120, 160), 'S%d' % n, font=font, fill='white', anchor='mm')
    im.save(os.path.join(SEED, 's%d.jpg' % n), quality=80)

D = dt.date


def days(a, b):
    x = a
    while x <= b:
        yield x
        x += dt.timedelta(days=1)


daily = []
for i, d in enumerate(days(D(2025, 8, 15), D(2026, 10, 18))):
    if i % 11 == 5 or D(2026, 1, 1) <= d <= D(2026, 1, 10) or d == D(2026, 10, 10):
        continue
    daily.append(d)
daily += [D(2026, 5, 5), D(2026, 6, 6)]  # two check-ins in one period

weekly = []  # (date, angles) angles: 1 = Left only, 3 = Left + Right
w = D(2024, 10, 23)  # a Wednesday
i = 0
while w < D(2026, 10, 19):
    if i % 6 != 4:
        weekly.append((w, 1 if i % 3 == 0 else 3))
    w += dt.timedelta(days=7)
    i += 1

monthly = []
for i in range(36):
    y, m = 2023 + (9 + i) // 12, (9 + i) % 12 + 1
    if i % 7 != 6:
        monthly.append(D(y, m, 15))

ep = D(1970, 1, 1)
spec = {
    'daily': [(d - ep).days for d in daily],
    'weekly': [[(d - ep).days, a] for d, a in weekly],
    'monthly': [(d - ep).days for d in monthly],
}
json.dump({k: [str(x) for x in v] for k, v in {'daily': daily, 'weekly': [d for d, _ in weekly], 'monthly': monthly}.items()},
          open(os.path.join('qa', 'steps', 'p28-seed-dates.json'), 'w'), indent=0)

repo = os.path.abspath('.').replace('\\', '/')
body = f"""
final session = c.read(secureVaultSessionProvider);
if (session == null) {{ throw StateError('vault locked'); }}
final svc = c.read(photoSeriesServiceProvider);
final imgs = [];
for (var n = 0; n < 10; n++) {{ final r = ui.PictureRecorder(); final cv = Canvas(r); cv.drawRect(Rect.fromLTWH(0, 0, 240, 320), Paint()..color = Color(0xFF203040 + n * 0x0A0C10)); cv.drawRect(Rect.fromLTWH(10.0 + 20.0 * n, 40, 24, 240), Paint()..color = Color(0xFFFFFFFF)); final im = await r.endRecording().toImage(240, 320); final bd = await im.toByteData(format: ui.ImageByteFormat.png); imgs.add(bd!.buffer.asUint8List()); }}
DateTime day(int d) {{ final u = DateTime.utc(1970, 1, 1).add(Duration(days: d)); return DateTime(u.year, u.month, u.day); }}
final dailyDays = {spec['daily']};
final weeklyDays = {spec['weekly']};
final monthlyDays = {spec['monthly']};
final sd = await svc.createSeries(name: 'P28 Daily seed', cadence: TrackerCadence.daily, sortOrder: 1);
final sw = await svc.createSeries(name: 'P28 Weekly seed', cadence: TrackerCadence.weekly, sortOrder: 2, angleNames: ['Left', 'Right']);
final sm = await svc.createSeries(name: 'P28 Monthly seed', cadence: TrackerCadence.monthly, sortOrder: 3);
await Future.delayed(Duration(seconds: 2)); final snap = await c.read(photoSeriesSnapshotProvider.future);
String angleOf(String sid, int order) => snap.angles.firstWhere((a) => a.seriesId == sid && a.sortOrder == order).id;
final ad = angleOf(sd.id, 0); final al = angleOf(sw.id, 0); final ar = angleOf(sw.id, 1); final am = angleOf(sm.id, 0);
var k = 0;
for (final d in dailyDays) {{ await svc.createCheckIn(session: session, series: sd, takenOn: day(d), photos: {{ad: imgs[k % 10]}}.cast()); k++; }}
debugPrint('P28SEED daily ' + k.toString());
for (final p in weeklyDays) {{ final ph = <String, dynamic>{{al: imgs[k % 10]}}; if (p[1] == 3) {{ ph[ar] = imgs[(k + 5) % 10]; }} await svc.createCheckIn(session: session, series: sw, takenOn: day(p[0]), photos: ph.cast()); k++; }}
debugPrint('P28SEED weekly ' + k.toString());
for (final d in monthlyDays) {{ await svc.createCheckIn(session: session, series: sm, takenOn: day(d), photos: {{am: imgs[k % 10]}}.cast()); k++; }}
debugPrint('P28SEED monthly ' + k.toString());
"""
assert '"' not in body and '//' not in body.replace('://', '')
open(os.path.join('qa', 'steps', 'p28-seed.dart.txt'), 'w').write(body.strip() + '\n')
print('daily', len(daily), 'weekly', len(weekly), 'monthly', len(monthly))
