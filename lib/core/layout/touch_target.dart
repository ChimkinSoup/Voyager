import 'package:flutter/widgets.dart';

/// Android's minimum touch target, as `IconButton.constraints`.
///
/// Dense toolbars set `padding: EdgeInsets.zero` to stop Material padding a
/// 16px glyph out to 48px of visual weight — but passing a bare
/// `BoxConstraints()` alongside it also throws away the tap padding, leaving a
/// button literally the size of its icon. This keeps the two separable: the
/// icon stays whatever size it was authored at, and only the hit area grows
/// back to something a fingertip can land on.
const kMinTouchTarget = BoxConstraints(minWidth: 48, minHeight: 48);
