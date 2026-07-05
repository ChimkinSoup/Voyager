import 'package:flutter/material.dart';

/// Wraps a child in a local Overlay and ClipRect so that any Overlay items 
/// (like ReorderableListView drag feedback) are clipped to the bounds of the child.
class LocalOverlayWrapper extends StatefulWidget {
  final Widget child;

  const LocalOverlayWrapper({super.key, required this.child});

  @override
  State<LocalOverlayWrapper> createState() => _LocalOverlayWrapperState();
}

class _LocalOverlayWrapperState extends State<LocalOverlayWrapper> {
  late final OverlayEntry _entry;

  @override
  void initState() {
    super.initState();
    _entry = OverlayEntry(
      builder: (context) => widget.child,
      canSizeOverlay: true,
    );
  }

  @override
  void didUpdateWidget(covariant LocalOverlayWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child != widget.child) {
      // Re-evaluate the builder to use the new child
      _entry.markNeedsBuild();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Overlay(
      initialEntries: [_entry],
      clipBehavior: Clip.hardEdge,
    );
  }
}
