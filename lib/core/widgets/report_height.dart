import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Reports its child's height after every layout that changes it.
///
/// Measured in the render tree rather than from a build because what grows
/// it — a failed save, a validation line — is a `setState` deep inside a
/// form, and reported off the frame rather than in a post-frame callback
/// because a hotkey floater's listener resizes the OS window: Win32's `SetWindowPlacement` pumps the message loop, which
/// re-enters Flutter's frame, and that asserts from anywhere inside one.
class ReportHeight extends SingleChildRenderObjectWidget {
  const ReportHeight({super.key, required this.onHeight, required super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderReportHeight createRenderObject(BuildContext context) =>
      RenderReportHeight(onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderReportHeight renderObject,
  ) => renderObject.onHeight = onHeight;
}

class RenderReportHeight extends RenderProxyBox {
  RenderReportHeight(this.onHeight);

  ValueChanged<double> onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    if (size.height == _reported) return;
    _reported = size.height;
    Timer.run(() {
      if (attached) onHeight(size.height);
    });
  }
}
