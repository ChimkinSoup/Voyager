import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/constants/build_info.dart';
import 'package:voyager/core/dev/error_logger.dart';

void main() {
  late Directory dir;
  late ErrorLogger logger;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('error_logger_test');
    ErrorLogger.directory = () async => dir.path;
    logger = ErrorLogger.forTesting();

    final originalFlutter = FlutterError.onError;
    final originalPlatform = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = originalFlutter;
      PlatformDispatcher.instance.onError = originalPlatform;
    });
  });

  tearDown(() async {
    await logger.readLog();
    dir.deleteSync(recursive: true);
  });

  test('nothing is written before install', () async {
    logger.record(StateError('from a test'), null);

    expect(await logger.readLog(), isEmpty);
  });

  test('an error is written with its context, stack and build', () async {
    logger.install();
    logger.record(
      StateError('boom'),
      StackTrace.fromString('#0 somewhere (file.dart:1:1)'),
      context: 'VoyagerBootstrap while registering global hotkeys',
    );

    final log = await logger.readLog();
    expect(log, contains('ERROR  build $buildLabel'));
    expect(
      log,
      contains(
        'VoyagerBootstrap while registering global hotkeys: '
        'Bad state: boom',
      ),
    );
    expect(log, contains('#0 somewhere (file.dart:1:1)'));
  });

  test(
    'an error repeated in quick succession is counted, not rewritten',
    () async {
      logger.install();
      for (var i = 0; i < 5; i++) {
        logger.record(StateError('every frame'), null, context: 'build');
      }
      logger.record(StateError('something else'), null);

      final log = await logger.readLog();
      expect('every frame'.allMatches(log).length, 1);
      expect(log, contains('(previous error repeated 4 more times)'));
      expect(log, contains('something else'));
    },
  );

  test('install logs both channels and keeps the previous handlers', () async {
    final forwarded = <Object>[];
    FlutterError.onError = (details) => forwarded.add(details.exception);
    PlatformDispatcher.instance.onError = (error, _) {
      forwarded.add(error);
      return true;
    };

    logger.install();
    FlutterError.reportError(
      FlutterErrorDetails(exception: StateError('from a widget')),
    );
    final handled = PlatformDispatcher.instance.onError!(
      StateError('from a future'),
      StackTrace.empty,
    );

    final log = await logger.readLog();
    expect(log, contains('=== APP START'));
    expect(log, contains('from a widget'));
    expect(log, contains('uncaught: Bad state: from a future'));
    expect(forwarded, hasLength(2));
    expect(handled, isTrue);
  });
}
