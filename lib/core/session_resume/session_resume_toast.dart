import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';

/// Tells the user the session they are looking at is the one they left, and
/// offers the way out of it.
///
/// Continuing is not a button: the restored session is already on screen by
/// the time this shows, so dismissing the toast — or ignoring it — is
/// continuing. Start over is the only thing there is to decide.
void showSessionResumeToast(
  BuildContext context, {
  required int remaining,
  required VoidCallback onStartOver,
}) => showVoyagerToast(
  context,
  message: 'Resuming your previous session · $remaining left',
  icon: PhosphorIconsRegular.clockCounterClockwise,
  dwell: const Duration(seconds: 10),
  actions: [VoyagerToastAction(label: 'Start over', onPressed: onStartOver)],
);
