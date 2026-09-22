import 'package:flutter/foundation.dart';

/// How much room something pinned to the top of the shell is taking right now,
/// gap included — or zero when the top is clear, which is the ordinary case.
///
/// Toasts are drawn in the root overlay, which is a *sibling* of the app shell
/// rather than a descendant, so nothing an overlay entry can reach through its
/// context knows that a shell-level layer is already sitting where the toast
/// is about to land. The live workout's island is exactly that: it pins itself
/// to the same anchor a toast uses, so a copy confirmation dropped straight on
/// top of it and hid the set the user was in the middle of.
///
/// This is the channel between them. Whatever holds the top publishes the
/// space it needs here and clears it on the way out; [showVoyagerToast]'s stack
/// starts below that instead of on top of it. A global rather than an
/// inherited value because the two layers have no common ancestor below the
/// navigator.
final topChromeInset = ValueNotifier<double>(0);
