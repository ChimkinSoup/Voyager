"""O1 of qa/MULTI_DEVICE_SYNC_TEST_PLAN.md: row diff of two Voyager databases.

Usage: python qa/harness/dbdiff.py [A] [B] [--tables t1,t2] [--show N] [--all-cols]
  A, B: a profile name (qa, qb, ...) or a path to a voyager.sqlite. Default qa qb.
  --tables  only these tables (substring match on the table name)
  --show    print up to N rows per category per table (default 5)

Read-only (mode=ro). Compares every table both databases have, keyed by its
primary key, on all columns except device-local state (IGNORE_TABLES,
IGNORE_COLS). Version-0 rows that differ only in created_at/updated_at
(built-ins each device seeds locally) are listed as ignored. Text dates are
compared as instants (local+offset vs UTC Z of the same moment are equal).
settings_table is compared only on the synced settings
(settingsSyncPayload keys). Prints, per table, rows only on A, only on B and
differing (with the differing columns), then a one-line verdict:
  DBDIFF SAME (n tables, m rows)   or   DBDIFF DIFF (k tables differ)
Exit code 0 when same, 1 when different.
"""
import os
import re
import sqlite3
import sys

# Device-local tables: the outbox, sync bookkeeping, conflicts, local logs.
IGNORE_TABLES = {
    'pending_uploads_table',
    'sync_watermarks_table',
    'sync_conflicts_table',
    'sync_conflicts',
    'pending_remote_deletes_table',  # MD-18: purge deletes this device owes Storage
}
IGNORE_TABLE_PATTERNS = [re.compile(p) for p in (r'^sqlite_', r'^drift_', r'^android_')]

# Columns that are device-local wherever they appear.
IGNORE_COLS = {
    'upload_state', 'download_state', 'local_path', 'upload_attempts',
    'download_attempts', 'last_upload_error', 'last_download_error',
    'field_updated_at_json',  # re-serialised on launch (PROGRESS P19A)
    'thumb_download_state', 'failure_reason',  # MD-18: vault_blobs transfer state
    'lost_note_count',  # MD-18: secure_vault_header_table, never synced
}

# Stamps a version-0 built-in (default calendar, workout plans, seeds) gets
# when each device creates it locally.
V0_LOCAL_COLS = {'created_at', 'updated_at'}

# settingsSyncPayload keys (lib/core/sync/firestore_document_mapper.dart).
SYNCED_SETTINGS = """accentColor themeMode petalColor minorPetalColors petalMaxCount petalFallSpeed
petalWindFrequency petalWindStrength weekStartsOnMonday showQuotes customQuotesOnly
showDefaultTrackersInGrid showDefaultTrackersInCalendar journalHotkey todoHotkey financeHotkey
reminderHotkey calendarNavigateLeftKey calendarNavigateRightKey srsFailKey srsHardKey srsGoodKey
srsEasyKey timelineModeYearZero birthYear birthDate alertOnPeriodicPrompts alertTimeHour
hideCompletedTasks vimModeEnabled snippetsEnabled autocorrectEnabled capsLockIndicatorEnabled
mediaRemoteUploadsEnabled mediaRemoteDownloadsEnabled mediaBackgroundPrefetchEnabled
snippetExpandKey defaultJournalId defaultTodoListId geometricTextureScale
geometricTextureIntensity geometricTextureFocalSpread geometricTextureFocalPointX
geometricTextureFocalPointY geometricTextureVariationFloor geometricWaveEnabled
geometricWaveShape geometricWaveDirectionDegrees geometricWaveSpeed geometricWaveWidth
geometricWavePeriod geometricWavePopHoldSeconds geometricWavePopScale geometricWavePopBrightness
geometricWaveMaskDensity geometricWaveMaskClusterScale geometricWaveTwinkleSparsity
geometricWaveShadowLightDegrees geometricWaveShadowOffset geometricWaveShadowSoftness
geometricWaveShadowStrength geometricWavePopBrightnessVariance geometricWaveTiltAmount
geometricWaveTiltShading geometricWaveMassLagSeconds geometricWaveMassSpring
geometricWaveScatterMode geometricWaveScatterLitAmount weatherChartTempColor
weatherChartRainColor weatherChartCurveTension colorPalette navPageOrder hiddenNavPages
jobsHiddenColumns jobsIncludeArchived rankingsCollapsedQueueCategories rankingsMapViewCategories
jobProfileLinkedInUrl jobProfileGitHubUrl jobProfilePortfolioUrl startupPageMode
customStartupPage showAnnualizedSubscriptionCost showDreamStatistics dreamNotesPinned
leetcodeUsername showNeetCode150 leetCodeHideDifficulty leetCodeHideTags leetCodeHideQuestionName
leetCodeHideDescription leetCodeHideExamples leetCodeHideComplexity leetCodeHideCode
leetCodeEnableScratchCode weightUnit workoutRestTimerEnabled workoutRestSeconds
showWorkoutsOnCalendar showWorkoutStatistics""".split()


# Drift's text dates: a device that wrote a local DateTime stores
# '2026-10-12T19:52:14.222 -04:00', and one that pulled the same value stores
# '2026-10-12T23:52:14.222Z'. Same instant, so compare them as instants.
ISO_RE = re.compile(r'^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,6}))? ?(Z|[+-]\d\d:\d\d)$')


def instant(v):
    if not isinstance(v, str):
        return v
    m = ISO_RE.match(v)
    if not m:
        return v
    from datetime import datetime, timezone
    tz = '+00:00' if m.group(3) == 'Z' else m.group(3)
    dt = datetime.fromisoformat(f'{m.group(1)}.{(m.group(2) or "0").ljust(6, "0")}{tz}')
    return dt.astimezone(timezone.utc)


def same(x, y):
    return x == y or instant(x) == instant(y)


def snake(name):
    return re.sub(r'(?<=[a-z0-9])([A-Z])', r'_\1', name).lower()


def db_path(arg):
    if os.path.isfile(arg):
        return arg
    return os.path.join(os.environ['APPDATA'], 'Voyager', 'voyager-profile-' + arg, 'voyager.sqlite')


def connect(arg):
    p = db_path(arg).replace('\\', '/')
    return sqlite3.connect('file:' + p + '?mode=ro', uri=True, timeout=10)


def tables(con):
    out = {}
    for (t,) in con.execute("select name from sqlite_master where type='table'"):
        if t in IGNORE_TABLES or any(p.search(t) for p in IGNORE_TABLE_PATTERNS):
            continue
        info = con.execute(f'pragma table_info("{t}")').fetchall()
        cols = [r[1] for r in info]
        pk = [r[1] for r in sorted(info, key=lambda r: r[5]) if r[5] > 0] or (['id'] if 'id' in cols else cols)
        out[t] = (cols, pk)
    return out


def load(con, t, cols, pk):
    rows = {}
    for r in con.execute(f'select {",".join(chr(34) + c + chr(34) for c in cols)} from "{t}"'):
        d = dict(zip(cols, r))
        rows[tuple(d[k] for k in pk)] = d
    return rows


def main(argv):
    args = [a for a in argv if not a.startswith('--')]
    opts = dict(a[2:].split('=', 1) if '=' in a else (a[2:], '1') for a in argv if a.startswith('--'))
    a_name, b_name = (args + ['qa', 'qb'])[:2] if len(args) < 2 else args[:2]
    show = int(opts.get('show', 5))
    filt = [f for f in opts.get('tables', '').split(',') if f]
    ca, cb = connect(a_name), connect(b_name)
    ta, tb = tables(ca), tables(cb)
    synced = {snake(k) for k in SYNCED_SETTINGS}
    differ, total, v0_stamps = [], 0, []
    for t in sorted(set(ta) | set(tb)):
        if filt and not any(f in t for f in filt):
            continue
        if t not in ta or t not in tb:
            print(f'{t}: table only on {"A" if t in ta else "B"}')
            differ.append(t)
            continue
        cols = [c for c in ta[t][0] if c in tb[t][0] and c not in IGNORE_COLS]
        if t == 'settings_table':
            cols = [c for c in cols if c in synced or c == 'id']
        pk = ta[t][1]
        ra, rb = load(ca, t, cols, pk), load(cb, t, cols, pk)
        total += len(ra)
        only_a = [k for k in ra if k not in rb]
        only_b = [k for k in rb if k not in ra]
        diff = []
        for k in ra:
            if k in rb and ra[k] != rb[k]:
                cs = [c for c in cols if not same(ra[k][c], rb[k][c])]
                if not cs:
                    continue
                # A built-in each device seeds for itself at version 0 (never
                # uploaded) differs only in its local stamps: not a sync diff.
                if ra[k].get('version') == 0 == rb[k].get('version') and set(cs) <= V0_LOCAL_COLS:
                    v0_stamps.append((t, k))
                    continue
                diff.append((k, cs))
        if not (only_a or only_b or diff):
            continue
        differ.append(t)
        print(f'{t}: onlyA={len(only_a)} onlyB={len(only_b)} differ={len(diff)}')
        for k in only_a[:show]:
            print(f'  onlyA {k}')
        for k in only_b[:show]:
            print(f'  onlyB {k}')
        for k, cs in diff[:show]:
            print(f'  differ {k}: ' + '; '.join(f'{c}: A={str(ra[k][c])[:60]!r} B={str(rb[k][c])[:60]!r}' for c in cs))
    if v0_stamps:
        print(f'(ignored: {len(v0_stamps)} version-0 rows differing only in local created/updated stamps: '
              + ', '.join(f'{t}{k}' for t, k in v0_stamps[:show]) + ')')
    if differ:
        print(f'DBDIFF DIFF ({len(differ)} tables differ)')
        return 1
    print(f'DBDIFF SAME ({len(set(ta) & set(tb))} tables, {total} rows)')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
