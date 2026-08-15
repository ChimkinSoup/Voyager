import 'package:flutter/material.dart';

/// Caret reveal inset for Voyager [TextField]s.
///
/// Flutter defaults to 20px. [EditableText] inflates the caret by that
/// padding and asks ancestor scrollables to [Scrollable.ensureVisible]. At
/// the top of a rubber-banding scroll view that extra inset cannot be
/// satisfied, so the view overscrolls and snaps back on every caret tick.
/// Zero still keeps the caret on screen; sheets already pad for the keyboard
/// via [MediaQuery.viewInsets].
const EdgeInsets kVoyagerFieldScrollPadding = EdgeInsets.zero;
