import 'package:flutter/widgets.dart';
import 'package:voyager/core/snippets/snippet_index.dart';
import 'package:voyager/domain/models/snippet.dart';

/// Publishes the user's text-snippet settings to every text field below.
///
/// Installed once at the app root beside [VimEnabledScope] (see
/// `voyager_app.dart`), and read the same way — through an inherited
/// dependency, so editing the snippet list re-applies to every mounted field
/// without any of them holding a Riverpod ref.
///
/// [index] is the compiled form of the list, built once per settings change
/// rather than per field or per keystroke; see [SnippetIndex].
@immutable
class SnippetScopeData {
  const SnippetScopeData({
    required this.enabled,
    required this.expandKey,
    required this.index,
  });

  static final SnippetScopeData disabled = SnippetScopeData(
    enabled: false,
    expandKey: SnippetExpandKey.tab,
    index: SnippetIndex.empty,
  );

  final bool enabled;
  final SnippetExpandKey expandKey;
  final SnippetIndex index;

  /// Whether a field should bother mounting a session at all. An empty list
  /// can never expand anything, so the whole feature costs nothing until the
  /// user writes their first snippet.
  bool get active => enabled && !index.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is SnippetScopeData &&
      other.enabled == enabled &&
      other.expandKey == expandKey &&
      other.index == index;

  @override
  int get hashCode => Object.hash(enabled, expandKey, index);
}

class SnippetEnabledScope extends InheritedWidget {
  const SnippetEnabledScope({
    super.key,
    required this.data,
    required super.child,
  });

  final SnippetScopeData data;

  static SnippetScopeData of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<SnippetEnabledScope>();
    return scope?.data ?? SnippetScopeData.disabled;
  }

  @override
  bool updateShouldNotify(SnippetEnabledScope oldWidget) =>
      oldWidget.data != data;
}
