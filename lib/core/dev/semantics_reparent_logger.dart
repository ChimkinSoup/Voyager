import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Debug-only trace for the Windows engine's console error
/// `Failed to update ui::AXTree, error: N will not be in the tree and is not
/// the new root`.
///
/// The engine only builds an accessibility tree once something asks the
/// window over UI Automation, so the first line says when that happened. The
/// error itself comes from a semantics node moving to a new parent in one
/// update, which the Windows bridge can't apply, so each such move is printed
/// with the widgets that own it. Both land in the same console as the engine's
/// error, just before it: match `N` against the `[a11y] node N` lines.
void installSemanticsReparentLogger(String app) {
  if (!kDebugMode) return;
  final binding = WidgetsBinding.instance;
  void reportEnabled() => debugPrint(
    '[a11y] $app: semantics '
    '${binding.semanticsEnabled ? 'ON (something read this window over UI Automation)' : 'off'}'
    ' at ${DateTime.now().toIso8601String()}',
  );
  if (binding.semanticsEnabled) reportEnabled();
  binding.addSemanticsEnabledListener(reportEnabled);
  var parents = <int, int>{};
  // Walked only after a frame that sent a semantics update.
  final heard = Expando<bool>();
  var updated = true;
  // Registered after the binding's own, so it runs once semantics are
  // flushed for the frame.
  SchedulerBinding.instance.addPersistentFrameCallback((_) {
    if (!binding.semanticsEnabled) {
      parents = {};
      updated = true;
      return;
    }
    for (final view in binding.renderViews) {
      final owner = view.owner?.semanticsOwner;
      if (owner == null || heard[owner] != null) continue;
      heard[owner] = true;
      owner.addListener(() => updated = true);
      updated = true;
    }
    if (!updated) return;
    updated = false;
    final now = <int, int>{};
    final nodes = <int, SemanticsNode>{};
    void walk(SemanticsNode node) {
      nodes[node.id] = node;
      node.visitChildren((child) {
        now[child.id] = node.id;
        walk(child);
        return true;
      });
    }

    for (final view in binding.renderViews) {
      final root = view.owner?.semanticsOwner?.rootSemanticsNode;
      if (root != null) walk(root);
    }
    final moved = [
      for (final MapEntry(key: id, value: parent) in now.entries)
        if (parents[id] case final old? when old != parent) (id, old, parent),
    ];
    parents = now;
    if (moved.isEmpty) return;
    final owners = _owners(binding);
    for (final (id, from, to) in moved) {
      debugPrint(
        '[a11y] $app: node $id moved parent $from -> $to at '
        '${DateTime.now().toIso8601String()}\n'
        '  node: ${_describe(nodes[id]!)}\n'
        '  owner: ${_owner(nodes[id]!, owners)}\n'
        '  old parent: ${_ownerOf(from, nodes, owners)}\n'
        '  new parent: ${_owner(nodes[to]!, owners)}',
      );
    }
  });
}

/// Every render object that owns a semantics node, by that node's id.
Map<int, RenderObject> _owners(WidgetsBinding binding) {
  final owners = <int, RenderObject>{};
  void visit(RenderObject object) {
    if (object.debugSemantics case final node?) {
      owners.putIfAbsent(node.id, () => object);
    }
    object.visitChildren(visit);
  }

  binding.renderViews.forEach(visit);
  return owners;
}

String _describe(SemanticsNode node) {
  final data = node.getSemanticsData();
  final label = data.label.replaceAll('\n', ' ');
  return '"${label.length > 60 ? '${label.substring(0, 60)}…' : label}" '
      'rect ${node.rect}';
}

/// The widgets behind [node], or behind its nearest ancestor that has a
/// render object of its own (a merged or implicit node doesn't).
String _owner(SemanticsNode node, Map<int, RenderObject> owners) {
  for (SemanticsNode? n = node; n != null; n = n.parent) {
    final object = owners[n.id];
    if (object == null) continue;
    final via = n == node ? '' : ' (via ancestor node ${n.id})';
    return '${object.debugCreator ?? object.runtimeType}$via';
  }
  return 'unknown';
}

/// [id] is gone from this frame's tree when its node was the one dropped.
String _ownerOf(
  int id,
  Map<int, SemanticsNode> nodes,
  Map<int, RenderObject> owners,
) => switch (nodes[id]) {
  final node? => _owner(node, owners),
  null => 'node $id, no longer in the tree',
};
