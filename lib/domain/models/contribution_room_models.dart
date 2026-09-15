import 'dart:math' as math;

import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/soft_deletable.dart';

/// What an [AssetRoomEvent] records.
///
/// A transfer is two rows, one per asset, so each side carries its own
/// valuation: [transferOut] on the asset the money left, [transferIn] on the
/// one it arrived at.
enum RoomEventKind { contribution, withdrawal, transferOut, transferIn }

extension RoomEventKindX on RoomEventKind {
  bool get isTransfer =>
      this == RoomEventKind.transferOut || this == RoomEventKind.transferIn;
}

/// One annual limit, in force from [fromYear] until a later entry replaces it.
class AnnualLimit {
  const AnnualLimit({required this.fromYear, required this.cents});

  final int fromYear;
  final int cents;

  Map<String, dynamic> toJson() => {'fromYear': fromYear, 'cents': cents};

  /// Every well-formed entry in [raw], sorted by year. A list rather than a
  /// year-keyed map on purpose: Firestore merge writes replace a list whole,
  /// but keep any map key the upload omits, so a removed year would survive.
  static List<AnnualLimit> listFromJson(Object? raw) {
    if (raw is! List) return const [];
    final limits = <AnnualLimit>[
      for (final entry in raw)
        if (entry is Map &&
            entry['fromYear'] is num &&
            entry['cents'] is num)
          AnnualLimit(
            fromYear: (entry['fromYear'] as num).toInt(),
            cents: (entry['cents'] as num).toInt(),
          ),
    ];
    limits.sort((a, b) => a.fromYear.compareTo(b.fromYear));
    return limits;
  }

  @override
  bool operator ==(Object other) =>
      other is AnnualLimit && other.fromYear == fromYear && other.cents == cents;

  @override
  int get hashCode => Object.hash(fromYear, cents);
}

/// A shared yearly contribution cap (a TFSA, an FHSA, …) that one or more
/// [Asset]s draw on.
///
/// Nothing about a year is stored. The room holds only what the user told it
/// when tracking began — [baselineRemainingCents] as of [baselineAsOf] — and
/// every later year is recomputed from that plus the room's events (see
/// [roomYearSummary]). A contribution that syncs in after New Year therefore
/// corrects the next year by itself, where a rollover written to disk would
/// have baked the gap in.
class ContributionRoom extends SoftDeletable {
  const ContributionRoom({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    required this.baselineRemainingCents,
    required this.baselineAsOf,
    this.annualLimits = const [],
  });

  final String name;

  /// Room left at [baselineAsOf]. May be negative: an over-contributed room.
  final int baselineRemainingCents;

  /// The local instant the baseline was entered. An instant rather than a day
  /// so a contribution logged earlier the same day — already inside the
  /// figure the user typed — is not subtracted a second time.
  final DateTime baselineAsOf;

  /// Yearly add-ons, ascending by [AnnualLimit.fromYear]. Kept per year so
  /// editing the limit changes this year and later, never a year that has
  /// already rolled.
  final List<AnnualLimit> annualLimits;

  /// The limit added on Jan 1 of [year], or 0 before the first entry.
  int annualLimitFor(int year) {
    var cents = 0;
    for (final limit in annualLimits) {
      if (limit.fromYear > year) break;
      cents = limit.cents;
    }
    return cents;
  }

  /// [annualLimits] with [cents] in force from [year] on, replacing whatever
  /// was set for [year] or after.
  List<AnnualLimit> annualLimitsFrom(int year, int cents) => [
    for (final limit in annualLimits)
      if (limit.fromYear < year) limit,
    AnnualLimit(fromYear: year, cents: cents),
  ];

  ContributionRoom copyWith({
    String? name,
    int? baselineRemainingCents,
    DateTime? baselineAsOf,
    List<AnnualLimit>? annualLimits,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
  }) {
    return ContributionRoom(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
      baselineRemainingCents:
          baselineRemainingCents ?? this.baselineRemainingCents,
      baselineAsOf: baselineAsOf ?? this.baselineAsOf,
      annualLimits: annualLimits ?? this.annualLimits,
    );
  }
}

/// Cash moving into, out of, or within a [ContributionRoom] through one asset.
class AssetRoomEvent extends SoftDeletable {
  const AssetRoomEvent({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.assetId,
    required this.roomId,
    required this.kind,
    required this.amountCents,
    required this.occurredAt,
    this.transactionId,
    this.valuationId,
    this.counterAssetId,
    this.transferGroupId,
    this.note,
  });

  final String assetId;

  /// The room at write time, kept even if the asset later leaves it: room
  /// math sums by this, so a detached asset's history still counts.
  final String roomId;

  final RoomEventKind kind;

  /// Magnitude, always >= 0; [kind] carries the direction.
  final int amountCents;

  /// Local wall-clock. Its calendar day decides settled vs upcoming.
  final DateTime occurredAt;

  /// The paired ledger row. Null for transfers, which move no cash.
  final String? transactionId;

  /// The valuation this event last wrote, if any.
  final String? valuationId;

  /// A transfer's other asset.
  final String? counterAssetId;

  /// Shared by a transfer's two legs.
  final String? transferGroupId;

  final String? note;

  AssetRoomEvent copyWith({
    String? assetId,
    RoomEventKind? kind,
    int? amountCents,
    DateTime? occurredAt,
    String? transactionId,
    String? valuationId,
    String? counterAssetId,
    String? note,
    bool clearNote = false,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
  }) {
    return AssetRoomEvent(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
      deletedAt: deletedAt ?? this.deletedAt,
      assetId: assetId ?? this.assetId,
      roomId: roomId,
      kind: kind ?? this.kind,
      amountCents: amountCents ?? this.amountCents,
      occurredAt: occurredAt ?? this.occurredAt,
      transactionId: transactionId ?? this.transactionId,
      valuationId: valuationId ?? this.valuationId,
      counterAssetId: counterAssetId ?? this.counterAssetId,
      transferGroupId: transferGroupId,
      note: clearNote ? null : (note ?? this.note),
    );
  }
}

/// A room's figures for one calendar year.
class RoomYearSummary {
  const RoomYearSummary({
    required this.year,
    required this.capacityCents,
    required this.usedCents,
  });

  final int year;

  /// Room available across the year: carry-over + limit + last year's
  /// withdrawals, or the baseline in the year tracking began.
  final int capacityCents;

  /// Settled contributions in the year.
  final int usedCents;

  int get remainingCents => capacityCents - usedCents;
  bool get isOver => remainingCents < 0;
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Whether [event] counts yet: dated on or before [now]'s calendar day, the
/// same rule [settledTransactions] applies to the ledger.
bool isRoomEventSettled(AssetRoomEvent event, DateTime now) =>
    !_day(event.occurredAt).isAfter(_day(now));

/// [room]'s figures for [year] (default: [now]'s year), derived from its
/// baseline and every settled contribution and withdrawal filed under it.
///
/// Rolls forward one Jan 1 at a time from the baseline's year:
/// `capacity(Y+1) = remaining(Y) + limit(Y+1) + withdrawals(Y)`. Withdrawals
/// never add room back inside their own year, and transfers never enter the
/// sums. Years before the baseline aren't tracked; asking for one returns the
/// baseline year.
RoomYearSummary roomYearSummary(
  ContributionRoom room,
  Iterable<AssetRoomEvent> events, {
  required DateTime now,
  int? year,
}) {
  final baseYear = room.baselineAsOf.year;
  final target = math.max(year ?? now.year, baseYear);

  final contributions = <int, int>{};
  final withdrawals = <int, int>{};
  // Contributions from before the baseline was entered are already inside
  // it: they fill the bar, so they have to widen the capacity too.
  var preBaseline = 0;
  for (final event in events) {
    if (event.roomId != room.id || event.deletedAt != null) continue;
    if (!isRoomEventSettled(event, now)) continue;
    final y = event.occurredAt.year;
    if (y < baseYear || y > target) continue;
    switch (event.kind) {
      case RoomEventKind.contribution:
        contributions[y] = (contributions[y] ?? 0) + event.amountCents;
        if (event.occurredAt.isBefore(room.baselineAsOf)) {
          preBaseline += event.amountCents;
        }
      case RoomEventKind.withdrawal:
        withdrawals[y] = (withdrawals[y] ?? 0) + event.amountCents;
      case RoomEventKind.transferOut:
      case RoomEventKind.transferIn:
        break;
    }
  }

  var capacity = room.baselineRemainingCents + preBaseline;
  for (var y = baseYear; y < target; y++) {
    final remaining = capacity - (contributions[y] ?? 0);
    capacity = remaining + room.annualLimitFor(y + 1) + (withdrawals[y] ?? 0);
  }
  return RoomYearSummary(
    year: target,
    capacityCents: capacity,
    usedCents: contributions[target] ?? 0,
  );
}

/// The live assets drawing on [roomId].
List<Asset> roomMembers(List<Asset> assets, String roomId) => [
  for (final asset in assets)
    if (asset.deletedAt == null && asset.contributionRoomId == roomId) asset,
];
