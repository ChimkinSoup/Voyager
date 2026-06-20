# ADR 003: Module Structure

## Status
Accepted

## Context
The app spans multiple feature areas with shared domain logic.

## Decision
- `domain/` for models, repository interfaces, and pure services.
- `data/` for Drift and remote adapters.
- `features/` for UI modules (auth, journal, todo, calendar, search, analytics, settings, hotkeys).
- `core/` for theme, sync primitives, and platform helpers.

## Consequences
- Feature modules depend inward on domain contracts.
- Android parity reuses domain/data with platform-specific shell behavior.
