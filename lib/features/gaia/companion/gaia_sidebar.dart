import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

const kGaiaSidebarMinWidth = 200.0;
const kGaiaSidebarMaxWidth = 420.0;

/// The narrowest the chat gets beside the sidebar before the sidebar hides.
const _chatRoom = 400.0;

/// The narrowest the chat gets beside a sidebar the user opened anyway.
const _squeezedChatRoom = 300.0;

/// How far past [kGaiaSidebarMinWidth] a drag goes to close the sidebar.
const _closeDrag = 48.0;

/// The Gaia window's sidebar: whether the user has it open and how wide.
/// Local to this desktop and never synced, like `GaiaDebug`: kept in a JSON
/// [file] beside Gaia's other files. Null in tests, which keep nothing.
class GaiaSidebar extends ChangeNotifier {
  GaiaSidebar({this.file});

  final File? file;

  var open = true;
  var width = 260.0;

  Future<void> load() async {
    final file = this.file;
    if (file == null || !await file.exists()) return;
    try {
      final json = jsonDecode(await file.readAsString()) as Map;
      open = json['open'] != false;
      if (json['width'] case final num width) {
        this.width = width.toDouble().clamp(
          kGaiaSidebarMinWidth,
          kGaiaSidebarMaxWidth,
        );
      }
    } catch (error) {
      debugPrint('[gaia] sidebar unreadable, using defaults: $error');
    }
    notifyListeners();
  }

  /// Neither is [save]d mid-drag: the drag saves once it's let go.
  Future<void> setOpen(bool value, {bool save = true}) =>
      _set(() => open = value, save: save);

  Future<void> setWidth(double value, {bool save = true}) =>
      _set(() => width = value, save: save);

  Future<void> _set(void Function() change, {bool save = true}) {
    change();
    notifyListeners();
    if (!save) return _saved;
    // In turn, so an older write never lands after a newer one.
    return _saved = _saved.then((_) => _save());
  }

  var _saved = Future<void>.value();

  Future<void> _save() async {
    final file = this.file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'open': open, 'width': width}));
    } catch (error) {
      debugPrint('[gaia] sidebar not saved: $error');
    }
  }
}

/// The Gaia window's sidebar beside its chat. The sidebar hides by itself
/// when the window is too narrow for both, and comes back when it widens;
/// its edge drags to resize it, and dragged well past its narrowest, closes
/// it. [chat] gets whether the sidebar shows and how to toggle it.
class GaiaSidebarLayout extends StatefulWidget {
  const GaiaSidebarLayout({
    super.key,
    required this.sidebar,
    required this.side,
    required this.chat,
  });

  final GaiaSidebar sidebar;
  final Widget side;
  final Widget Function(bool shown, VoidCallback toggle) chat;

  @override
  State<GaiaSidebarLayout> createState() => _GaiaSidebarLayoutState();
}

class _GaiaSidebarLayoutState extends State<GaiaSidebarLayout> {
  /// Opened by the user while the window is too narrow for it; cleared once
  /// the window has room again.
  var _squeezed = false;

  /// The width when the current drag began; null when not dragging. A drag
  /// that closes the sidebar goes on, and dragged back, reopens it.
  double? _dragFrom;
  var _dragged = 0.0;

  /// The width kept when the current drag began, which may be wider than
  /// the window lets it show.
  var _keptWidth = 0.0;

  @override
  Widget build(BuildContext context) {
    final sidebar = widget.sidebar;
    return ListenableBuilder(
      listenable: sidebar,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          // Less the divider.
          final room = constraints.maxWidth - 1;
          final fits = room - kGaiaSidebarMinWidth >= _chatRoom;
          if (fits) _squeezed = false;
          final shown = sidebar.open && (fits || _squeezed);
          final maxWidth = max(
            kGaiaSidebarMinWidth,
            min(
              kGaiaSidebarMaxWidth,
              room - (fits ? _chatRoom : _squeezedChatRoom),
            ),
          );
          final width = sidebar.width.clamp(kGaiaSidebarMinWidth, maxWidth);
          void toggle() {
            setState(() => _squeezed = !shown && !fits);
            sidebar.setOpen(!shown);
          }

          void dragged(double dx) {
            final from = _dragFrom;
            if (from == null) return;
            _dragged += dx;
            final wanted = from + _dragged;
            if (wanted < kGaiaSidebarMinWidth - _closeDrag) {
              if (!sidebar.open) return;
              // Reopens at the width it had before this drag.
              sidebar.setWidth(_keptWidth, save: false);
              setState(() => _squeezed = false);
              sidebar.setOpen(false, save: false);
              return;
            }
            if (!sidebar.open) {
              setState(() => _squeezed = !fits);
              sidebar.setOpen(true, save: false);
            }
            sidebar.setWidth(
              wanted.clamp(kGaiaSidebarMinWidth, maxWidth),
              save: false,
            );
          }

          void dragEnded() {
            if (_dragFrom == null) return;
            setState(() => _dragFrom = null);
            sidebar.setWidth(sidebar.width);
          }

          return Stack(
            children: [
              Row(
                children: [
                  if (shown) ...[
                    SizedBox(width: width, child: widget.side),
                    const VerticalDivider(width: 1),
                  ],
                  // Keyed, so the chat keeps its state as the sidebar comes
                  // and goes.
                  Expanded(
                    key: const ValueKey('chat'),
                    child: widget.chat(shown, toggle),
                  ),
                ],
              ),
              if (shown || _dragFrom != null)
                Positioned(
                  left: shown ? width - 4 : 0,
                  width: 9,
                  top: 0,
                  bottom: 0,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeColumn,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onHorizontalDragStart: (_) {
                        _dragFrom = width;
                        _keptWidth = sidebar.width;
                        _dragged = 0;
                      },
                      onHorizontalDragUpdate: (details) =>
                          dragged(details.delta.dx),
                      onHorizontalDragEnd: (_) => dragEnded(),
                      onHorizontalDragCancel: dragEnded,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
