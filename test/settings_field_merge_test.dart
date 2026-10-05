// Settings merge setting by setting (BUG-001's consequence): changing one
// setting on a device that hasn't pulled yet must not carry the rest of its
// default settings over the cloud copy, in either direction.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/settings_models.dart';

/// The real settings, last uploaded whole by a build from before stamps.
Map<String, dynamic> _legacyCloud() => settingsToFirestore(
  AppSettings(
    accentColor: 0xFFA6D189,
    showQuotes: false,
    themeMode: AppThemeMode.light,
    leetcodeUsername: 'juno',
    updatedAt: DateTime.utc(2026, 9, 27),
  ),
);

void main() {
  late AppDatabase db;
  late DriftSettingsRepository repo;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = DriftSettingsRepository(db);
  });
  tearDown(() => db.close());

  /// A fresh install that changes the accent before its first pull.
  Future<AppSettings> freshDeviceWithAccent(int accent) async {
    final defaults = await repo.getSettings();
    await repo.saveSettings(defaults.copyWith(accentColor: accent));
    return repo.getSettings();
  }

  test('a fresh device stamps only the setting it changed', () async {
    final local = await freshDeviceWithAccent(0xFF00BCD4);
    expect(local.fieldUpdatedAt!.keys, ['accentColor']);
  });

  test('a pull keeps the local change and takes every other setting', () async {
    final local = await freshDeviceWithAccent(0xFF00BCD4);
    final merged = mergeSettingsFromRemote(_legacyCloud(), local);

    expect(merged.accentColor, 0xFF00BCD4);
    expect(merged.showQuotes, isFalse);
    expect(merged.themeMode, AppThemeMode.light);
    expect(merged.leetcodeUsername, 'juno');
  });

  test('an upload before the pull writes only the changed setting', () async {
    final server = InMemorySyncRepository();
    await server.upsertRemoteSettings(_legacyCloud());

    await server.uploadSettings(await freshDeviceWithAccent(0xFF00BCD4));

    final cloud = (await server.getRemoteSettings())!;
    expect(cloud['accentColor'], 0xFF00BCD4);
    expect(cloud['showQuotes'], isFalse);
    expect(cloud['themeMode'], 'light');
    expect(cloud['leetcodeUsername'], 'juno');
  });

  test('an untouched fresh device uploads nothing', () async {
    final server = InMemorySyncRepository();
    await server.upsertRemoteSettings(_legacyCloud());
    final before = Map.of((await server.getRemoteSettings())!);

    await server.uploadSettings(await repo.getSettings());

    expect(await server.getRemoteSettings(), before);
  });

  test('two devices changing different settings both keep theirs', () async {
    final server = InMemorySyncRepository();
    final base = AppSettings(fieldUpdatedAt: const {});
    final a = base.copyWith(
      accentColor: 1,
      fieldUpdatedAt: {'accentColor': DateTime.utc(2026, 10, 1)},
      updatedAt: DateTime.utc(2026, 10, 1),
    );
    final b = base.copyWith(
      showQuotes: false,
      fieldUpdatedAt: {'showQuotes': DateTime.utc(2026, 10, 2)},
      updatedAt: DateTime.utc(2026, 10, 2),
    );
    await server.uploadSettings(a);
    await server.uploadSettings(b);

    final cloud = (await server.getRemoteSettings())!;
    for (final device in [a, b]) {
      final merged = mergeSettingsFromRemote(cloud, device);
      expect(merged.accentColor, 1);
      expect(merged.showQuotes, isFalse);
    }
  });

  test('an older value is never uploaded over a newer one', () async {
    final server = InMemorySyncRepository();
    await server.uploadSettings(
      AppSettings(
        accentColor: 2,
        fieldUpdatedAt: {'accentColor': DateTime.utc(2026, 10, 2)},
      ),
    );
    await server.uploadSettings(
      AppSettings(
        accentColor: 1,
        fieldUpdatedAt: {'accentColor': DateTime.utc(2026, 10, 1)},
      ),
    );
    expect((await server.getRemoteSettings())!['accentColor'], 2);
  });

  test('our own upload echoed back changes nothing', () async {
    final server = InMemorySyncRepository();
    final local = await freshDeviceWithAccent(0xFF00BCD4);
    await server.uploadSettings(local);

    final echoed = (await server.getRemoteSettings())!;
    expect(identical(mergeSettingsFromRemote(echoed, local), local), isTrue);
  });

  test('stamps overwritten by a build from before stamps are ignored', () async {
    final server = InMemorySyncRepository();
    await server.uploadSettings(
      AppSettings(
        accentColor: 1,
        fieldUpdatedAt: {'accentColor': DateTime.utc(2026, 10, 1)},
      ),
    );
    // The old build writes its whole document with a newer clock, leaving the
    // earlier stamps behind.
    await server.upsertRemoteSettings(
      settingsToFirestore(
        AppSettings(accentColor: 3, updatedAt: DateTime.utc(2026, 10, 3)),
      ),
    );

    final device = AppSettings(
      accentColor: 2,
      fieldUpdatedAt: {'accentColor': DateTime.utc(2026, 10, 2)},
    );
    final cloud = (await server.getRemoteSettings())!;
    expect(mergeSettingsFromRemote(cloud, device).accentColor, 3);
  });

  test('a row from before stamps keeps whole-document behaviour', () async {
    final local = AppSettings(
      accentColor: 5,
      showQuotes: true,
      updatedAt: DateTime.utc(2026, 9, 28),
    );
    // Older than the local clock: nothing applies.
    expect(identical(mergeSettingsFromRemote(_legacyCloud(), local), local),
        isTrue);
  });
}
