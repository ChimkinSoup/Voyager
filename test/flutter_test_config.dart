import 'dart:async';

import 'package:voyager/features/gaia/companion/gaia_aurora_edge.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  GaiaAuroraEdge.animate = false;
  await testMain();
}
