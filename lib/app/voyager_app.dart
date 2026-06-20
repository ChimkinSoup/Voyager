import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/routing/app_router.dart';

class VoyagerApp extends ConsumerWidget {
  const VoyagerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value;
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'Voyager',
      theme: VoyagerTheme.dark(
        accent: Color(settings?.accentColor ?? 0xFF7C9EFF),
      ),
      routerConfig: router,
    );
  }
}
