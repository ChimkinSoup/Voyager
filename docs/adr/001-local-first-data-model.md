# ADR 001: Local-First Data Model

## Status
Accepted

## Context
Voyager must work offline with full local copies per device and sync to Firestore.

## Decision
- Use Drift + SQLite as a single cross-platform local database.
- All entities use UUID primary keys with editable date metadata.
- Soft deletes retain records for 30 days before purge.

## Consequences
- Shared repository code across Windows and Android.
- Requires sync layer to upsert whole documents after debounce.
