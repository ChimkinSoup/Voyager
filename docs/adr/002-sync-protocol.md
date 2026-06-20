# ADR 002: Sync Protocol Boundaries

## Status
Accepted

## Context
Journal edits are debounced; to-do updates require live propagation.

## Decision
- Debounced document sync for journal and analytics payloads (default 3 seconds).
- Immediate Firestore writes + watchers for to-do list changes.
- Google Calendar ingest is read-only and guarded by a Firestore lock document.

## Consequences
- Two sync paths with explicit repository contracts.
- Conflict resolution uses operation-log sequence CRDT merging.
