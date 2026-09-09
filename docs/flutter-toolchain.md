# Flutter toolchain

Voyager is pinned to a specific Flutter SDK version on purpose. Do not run `flutter upgrade` without reading this first.

## Pinned version

| | |
|---|---|
| **Flutter** | 3.44.6 (stable) |
| **Dart** | 3.12.2 |
| **Channel** | stable |

Verify with:

```bash
flutter --version
```

Expected output includes `Flutter 3.44.6` and `Dart 3.12.2`.

## Why we are pinned

Upgrading to **Flutter 3.47** made the Windows desktop build run ~20°C hotter under normal use (roughly 70°C → 90°C on the same hardware). Downgrading back to 3.44.6 restored normal thermals.

The cause is **Impeller becoming the default renderer on Windows** in Flutter 3.47. Skia was the default on 3.44.6. Voyager is sensitive to this because it paints full-screen custom shaders and continuously animates backgrounds (`GeometricTexture`, `PetalField` — see `BACKGROUND.md`).

Upstream tracking:

- [flutter/flutter#191353](https://github.com/flutter/flutter/issues/191353) — Windows apps significantly slower with Impeller
- [flutter/flutter#191497](https://github.com/flutter/flutter/issues/191497) — Impeller higher RAM use on Windows
- [flutter/flutter#191860](https://github.com/flutter/flutter/issues/191860) — Impeller slower Windows startup

## Workaround: disable Impeller on 3.47+

If you need a newer Flutter for another reason, keep Impeller off on Windows.

### Per command (dev and release builds)

```bash
flutter run -d windows --no-enable-impeller
flutter build windows --no-enable-impeller
```

### Permanent (native project)

Add this in `windows/runner/main.cpp` after `flutter::DartProject project(L"data");` and before `FlutterWindow window(project);`:

```cpp
project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);
```

Then a normal `flutter build windows` uses Skia without passing the flag every time.

## Before running `flutter upgrade`

All of the following should be true:

1. **Impeller on Windows is acceptable** — either fixed upstream (watch the issues above) or disabled in `main.cpp` as above.
2. **Thermals re-checked** — run the app on Windows for several minutes with the usual theme (light = petal field, dark = geometric shader). CPU/temperature should match 3.44.6 behavior.
3. **Tests pass** — at minimum:
   ```bash
   flutter test
   flutter analyze
   ```
4. **Firebase pins reviewed** — `pubspec.yaml` pins `firebase_storage` and uses a patched `firebase_auth` in `third_party/`. A major Flutter/Firebase bump may require updating those together.
5. **SDK constraint** — if the new Flutter ships a newer Dart, update `environment.sdk` in `pubspec.yaml` only after `pub get` and tests succeed.

After upgrading, update the pinned version table at the top of this file.

## Day-to-day development

- Prefer `flutter pub get` over `flutter pub upgrade` while pinned.
- Bump individual packages only when needed; watch for new minimum Dart/Flutter requirements.
- Optional: install [FVM](https://fvm.app/) and pin `3.44.6` per project so a global `flutter upgrade` does not affect Voyager.

## Release builds (.exe) and Flutter version

A **release** Windows build (`flutter build windows`) bundles the Flutter engine, Dart runtime, your compiled app, and assets into the `build/windows/x64/runner/Release/` folder. End users run `voyager.exe` from that folder; they do **not** need Flutter installed.

The shipped binary is **frozen at build time**, similar to a Docker image: dependency versions and engine code are baked in. You do **not** need to keep upgrading Flutter to keep an already-built `.exe` running.

You only need the toolchain again when you want to:

- ship a new build with code or dependency changes
- fix a bug or security issue in your app
- rebuild for a new OS or store requirement

Runtime concerns (Firebase API changes, sync protocol, etc.) are separate from the Flutter SDK version and apply regardless of how the app was built.
