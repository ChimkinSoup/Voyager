# Voyager

Local-first journaling and productivity app for Windows and Android.

## Features

- **Auth**: email/password and Google OAuth via local in-memory adapter (Firebase can be added when wiring production sync)
- **Journal**: markdown editor, tags, multiple journals, debounced Firestore sync
- **To-do**: list grouping, live sync path, completion toggles
- **Calendar**: week/month/year views, local events, read-only Google Calendar ingest with lock
- **Search**: token-based keyword and tag search
- **Analytics**: statistic trackers, rankings, graphs, calendar heatmaps
- **Windows hotkeys**: quick journal and to-do popups (integration point via `hotkey_manager`)
- **Android parity**: shared domain/data modules with platform-specific UI affordances

## Architecture

- `domain/` — models, repository interfaces, pure services
- `data/` — Drift/SQLite repositories, sync adapters
- `features/` — UI modules
- `core/` — theme, sync primitives, platform helpers
- `docs/adr/` — architecture decision records

## Setup

```bash
flutter pub get
dart run build_runner build
flutter run -d windows
```

## Testing

```bash
flutter test
flutter analyze
```
