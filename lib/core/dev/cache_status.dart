import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum CacheItemState { notStarted, loading, loaded, failed }

@immutable
class CacheItemStatus {
  const CacheItemStatus({
    required this.label,
    required this.state,
    this.detail,
  });

  final String label;
  final CacheItemState state;
  final String? detail;

  bool get isComplete =>
      state == CacheItemState.loaded || state == CacheItemState.failed;
}

@immutable
class CacheStatusSnapshot {
  const CacheStatusSnapshot({required this.items});

  final List<CacheItemStatus> items;

  int get total => items.length;

  int get attempted =>
      items.where((item) => item.state != CacheItemState.notStarted).length;

  int get loaded =>
      items.where((item) => item.state == CacheItemState.loaded).length;

  int get loading =>
      items.where((item) => item.state == CacheItemState.loading).length;

  int get failed =>
      items.where((item) => item.state == CacheItemState.failed).length;

  double get loadedFraction => total == 0 ? 0 : loaded / total;

  int get loadedPercent => (loadedFraction * 100).round();

  double get attemptedFraction => total == 0 ? 0 : attempted / total;

  int get attemptedPercent => (attemptedFraction * 100).round();
}

CacheItemStatus cacheStatusFromAsync(String label, AsyncValue<dynamic> async) {
  return async.when(
    data: (_) => CacheItemStatus(label: label, state: CacheItemState.loaded),
    loading: () => CacheItemStatus(label: label, state: CacheItemState.loading),
    error: (error, _) => CacheItemStatus(
      label: label,
      state: CacheItemState.failed,
      detail: '$error',
    ),
  );
}

CacheItemStatus cacheStatusFromWarmup(String label, CacheItemState? state) {
  if (state == null) {
    return CacheItemStatus(label: label, state: CacheItemState.notStarted);
  }
  return CacheItemStatus(label: label, state: state);
}

String cacheStateLabel(CacheItemState state) {
  return switch (state) {
    CacheItemState.notStarted => 'Not started',
    CacheItemState.loading => 'Loading',
    CacheItemState.loaded => 'Cached',
    CacheItemState.failed => 'Failed',
  };
}

Color cacheStateColor(CacheItemState state, ColorScheme scheme) {
  return switch (state) {
    CacheItemState.notStarted => scheme.onSurface.withValues(alpha: 0.45),
    CacheItemState.loading => scheme.primary,
    CacheItemState.loaded => const Color(0xFF81C784),
    CacheItemState.failed => scheme.error,
  };
}
