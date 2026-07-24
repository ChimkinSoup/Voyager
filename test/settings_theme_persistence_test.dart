import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/settings_models.dart';

void main() {
  late AppDatabase db;
  late DriftSettingsRepository repo;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = DriftSettingsRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('defaults to the dark theme with the default petal field', () async {
    final settings = await repo.getSettings();
    expect(settings.themeMode, AppThemeMode.dark);
    expect(settings.petalColor, defaultPetalColor);
    expect(settings.petalMaxCount, 60);
  });

  test('persists the light theme and petal parameters across a reload', () async {
    final saved = (await repo.getSettings()).copyWith(
      themeMode: AppThemeMode.light,
      petalColor: 0xFFAABBCC,
      petalMaxCount: 120,
      petalFallSpeed: 55.5,
      petalWindFrequency: 0.3,
      petalWindStrength: 90.0,
    );
    await repo.saveSettings(saved);

    final loaded = await repo.getSettings();
    expect(loaded.themeMode, AppThemeMode.light);
    expect(loaded.petalColor, 0xFFAABBCC);
    expect(loaded.petalMaxCount, 120);
    expect(loaded.petalFallSpeed, closeTo(55.5, 1e-9));
    expect(loaded.petalWindFrequency, closeTo(0.3, 1e-9));
    expect(loaded.petalWindStrength, closeTo(90.0, 1e-9));
  });
}
