// Room math for FINANCE_CONTRIBUTION_ROOM_HLD.md: nothing about a year is
// stored, so every figure here is derived from the baseline and the events.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/contribution_room_models.dart';

final _t0 = DateTime.utc(2026, 1, 1);

ContributionRoom _room({
  int remaining = 700000,
  DateTime? asOf,
  List<AnnualLimit> limits = const [AnnualLimit(fromYear: 2026, cents: 700000)],
}) => ContributionRoom(
  id: 'room',
  createdAt: _t0,
  updatedAt: _t0,
  name: 'TFSA',
  baselineRemainingCents: remaining,
  baselineAsOf: asOf ?? DateTime(2026, 3, 1, 9),
  annualLimits: limits,
);

var _seq = 0;

AssetRoomEvent _event(
  RoomEventKind kind,
  int cents,
  DateTime at, {
  String roomId = 'room',
  DateTime? deletedAt,
}) => AssetRoomEvent(
  id: 'e${_seq++}',
  createdAt: _t0,
  updatedAt: _t0,
  deletedAt: deletedAt,
  assetId: 'a',
  roomId: roomId,
  kind: kind,
  amountCents: cents,
  occurredAt: at,
);

void main() {
  test('a fresh room is its baseline, nothing used', () {
    final s = roomYearSummary(_room(), const [], now: DateTime(2026, 3, 2));
    expect(s.year, 2026);
    expect(s.capacityCents, 700000);
    expect(s.usedCents, 0);
    expect(s.remainingCents, 700000);
  });

  test('a settled contribution uses room', () {
    final s = roomYearSummary(
      _room(),
      [_event(RoomEventKind.contribution, 150000, DateTime(2026, 3, 5, 12))],
      now: DateTime(2026, 3, 10),
    );
    expect(s.usedCents, 150000);
    expect(s.capacityCents, 700000);
    expect(s.remainingCents, 550000);
  });

  test('a post-dated contribution counts only once its day arrives', () {
    final events = [
      _event(RoomEventKind.contribution, 100000, DateTime(2026, 4, 1, 8)),
    ];
    expect(
      roomYearSummary(_room(), events, now: DateTime(2026, 3, 31, 23)).usedCents,
      0,
    );
    // Any time on the day itself, even before the event's clock time.
    expect(
      roomYearSummary(_room(), events, now: DateTime(2026, 4, 1, 0, 1)).usedCents,
      100000,
    );
  });

  test('a withdrawal restores nothing this year, and all of it on Jan 1', () {
    final events = [
      _event(RoomEventKind.contribution, 200000, DateTime(2026, 5, 1, 12)),
      _event(RoomEventKind.withdrawal, 50000, DateTime(2026, 6, 1, 12)),
    ];
    final thisYear = roomYearSummary(_room(), events, now: DateTime(2026, 7, 1));
    expect(thisYear.remainingCents, 500000);

    final nextYear = roomYearSummary(_room(), events, now: DateTime(2027, 1, 1));
    // Unused 5,000 + new 7,000 limit + 500 withdrawn last year.
    expect(nextYear.capacityCents, 500000 + 700000 + 50000);
    expect(nextYear.usedCents, 0);
  });

  test('transfers never touch the room', () {
    final events = [
      _event(RoomEventKind.transferOut, 300000, DateTime(2026, 5, 1, 12)),
      _event(RoomEventKind.transferIn, 300000, DateTime(2026, 5, 1, 12)),
    ];
    final s = roomYearSummary(_room(), events, now: DateTime(2026, 6, 1));
    expect(s.usedCents, 0);
    expect(s.remainingCents, 700000);
    expect(
      roomYearSummary(_room(), events, now: DateTime(2027, 6, 1)).capacityCents,
      1400000,
    );
  });

  test('earlier the same day as the baseline is already inside it', () {
    final events = [
      // Logged at 8:00, baseline typed at 9:00 — the typed figure has it.
      _event(RoomEventKind.contribution, 100000, DateTime(2026, 3, 1, 8)),
      // After the baseline: genuinely new room used.
      _event(RoomEventKind.contribution, 50000, DateTime(2026, 3, 1, 10)),
    ];
    final s = roomYearSummary(_room(), events, now: DateTime(2026, 3, 2));
    expect(s.usedCents, 150000, reason: 'the bar shows everything this year');
    expect(s.remainingCents, 650000, reason: 'only the later one is new');
  });

  test('over-contributing goes negative and carries into next year', () {
    final events = [
      _event(RoomEventKind.contribution, 800000, DateTime(2026, 5, 1, 12)),
    ];
    final s = roomYearSummary(_room(), events, now: DateTime(2026, 6, 1));
    expect(s.isOver, isTrue);
    expect(s.remainingCents, -100000);
    expect(
      roomYearSummary(_room(), events, now: DateTime(2027, 1, 1)).capacityCents,
      600000,
    );
  });

  test('a limit edited in 2028 leaves the 2027 roll alone', () {
    final room = _room(
      limits: const [
        AnnualLimit(fromYear: 2026, cents: 700000),
        AnnualLimit(fromYear: 2028, cents: 750000),
      ],
    );
    expect(
      roomYearSummary(room, const [], now: DateTime(2027, 2, 1)).capacityCents,
      1400000,
    );
    expect(
      roomYearSummary(room, const [], now: DateTime(2028, 2, 1)).capacityCents,
      2150000,
    );
  });

  test('annualLimitsFrom replaces this year and later only', () {
    final room = _room(
      limits: const [
        AnnualLimit(fromYear: 2026, cents: 700000),
        AnnualLimit(fromYear: 2029, cents: 1),
      ],
    );
    expect(room.annualLimitsFrom(2028, 750000), const [
      AnnualLimit(fromYear: 2026, cents: 700000),
      AnnualLimit(fromYear: 2028, cents: 750000),
    ]);
    expect(room.annualLimitFor(2025), 0);
  });

  test('a late-synced December contribution corrects the next year', () {
    final room = _room();
    final before = roomYearSummary(room, const [], now: DateTime(2027, 1, 2));
    final after = roomYearSummary(room, [
      _event(RoomEventKind.contribution, 200000, DateTime(2026, 12, 30, 12)),
    ], now: DateTime(2027, 1, 2));
    expect(before.capacityCents - after.capacityCents, 200000);
  });

  test('other rooms and deleted events are ignored', () {
    final events = [
      _event(
        RoomEventKind.contribution,
        100000,
        DateTime(2026, 5, 1, 12),
        roomId: 'other',
      ),
      _event(
        RoomEventKind.contribution,
        100000,
        DateTime(2026, 5, 1, 12),
        deletedAt: _t0,
      ),
    ];
    expect(
      roomYearSummary(_room(), events, now: DateTime(2026, 6, 1)).usedCents,
      0,
    );
  });

  test('AnnualLimit.listFromJson sorts and skips malformed entries', () {
    expect(
      AnnualLimit.listFromJson([
        {'fromYear': 2028, 'cents': 2},
        {'fromYear': 'x', 'cents': 1},
        'junk',
        {'fromYear': 2026, 'cents': 1},
      ]),
      const [
        AnnualLimit(fromYear: 2026, cents: 1),
        AnnualLimit(fromYear: 2028, cents: 2),
      ],
    );
    expect(AnnualLimit.listFromJson(null), isEmpty);
  });
}
