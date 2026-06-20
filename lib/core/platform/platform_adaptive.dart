import 'package:flutter/material.dart';
import 'package:voyager/core/platform/platform_info.dart';

class PlatformAdaptiveScaffold extends StatelessWidget {
  const PlatformAdaptiveScaffold({
    super.key,
    required this.body,
    this.floatingActionButton,
  });

  final Widget body;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    if (isAndroid) {
      return Scaffold(body: body, floatingActionButton: floatingActionButton);
    }
    return Scaffold(body: body, floatingActionButton: floatingActionButton);
  }
}
