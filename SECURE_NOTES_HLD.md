# Implementation plan: Secure Notes, plus conflict detection for Pinned Notes

## What I found that shapes the plan

- **Every upload today blindly overwrites the server copy.** Both the immediate upload (`pushRecords` → `syncDocumentsImmediately`, `remote_sync_service.dart:5801`) and the outbox drain (`batch.set(..., merge: true)`, `outbox_sync_worker.dart:375`) do this. Nothing compares versions before writing.
- **Firestore's offline cache makes it worse.** A plain write made offline sits in the Firestore SDK's queue. It's sent unchecked whenever the device reconnects, outside our control.
- **There's already a fix pattern.** Settings uploads use `runTransaction`, which reads the server copy and then writes (`firestore_sync_repository.dart:232`), in both the immediate and outbox paths. A transaction fails offline instead of queuing, so the edit falls back to the outbox and is retried with the check online. Conflict detection follows the same pattern.
- **Edits can also be lost on download.** `mergePinnedNoteFromRemote` (`firestore_document_mapper.dart:3305`) applies the later save without asking whether this device has an edit it hasn't uploaded. The outbox drains only after a catch-up download (`beforeDrain`). So the download path needs the check too, not just the upload.
- **Lock-on-close needs one guard.** An offstage pre-warmed copy of the popover exists (`notification_inbox_popover.dart:2457`). Locking when it closes does no harm, but it must never show decrypted notes.
- **Platforms:** Windows and Android. Firestore rules already cover any `users/{uid}/{collection}`, so they need no change.

## Phase 1: Conflict detection for Pinned Notes

This phase stands on its own and can ship before any encryption work.

**Idea:** each note remembers the server version it was last in step with (`syncedVersion`). A local edit that hasn't been uploaded meets a server copy that has also moved on since that version = a conflict.

**Rule for any conflict:** the original note takes the server's state. If this device's version isn't deleted, it's saved as a **new note** placed right after the original (`createdAt` + 1 ms; notes sort by `createdAt`). Both texts survive and nothing is silently dropped.
- **Edit on one device, delete on the other:** the edit survives.
- **Both devices deleted it:** not a conflict.
- **Identical text on both sides:** treated as already in step, not a conflict.

**Changes:**

1. **Schema (`app_database.dart`, bump from 145):**
   - Add a nullable `syncedVersion` integer to `PinnedNotesTable`.
   - Migration: for rows with no upload waiting in the outbox, set `syncedVersion = version`.
   - Rows still owed an upload get `null`, which means "no base known; use the old later-save-wins rule once". This way no existing note is mis-flagged as a conflict.
2. **Model and repository:**
   - Add `syncedVersion` to `PinnedNote`, `_mapNote` and `upsertPinnedNote`.
   - Add `markPinnedNoteSynced(id, version)`. It only advances `syncedVersion` if the row's version is still the one that was uploaded, so an edit made during the upload stays marked as not uploaded.
3. **Shared conflict function** in `firestore_document_mapper.dart`, as one pure function shared by Pinned Notes and Secure Notes. It takes the local row and the server data, and returns one of:
   - apply the server copy;
   - keep the local copy;
   - conflict: fork the local copy into a new note.
4. **Download (`pullPinnedNotes`, `remote_sync_service.dart:6789`):** use the new function. On "apply", set `syncedVersion` to the server's version.
5. **Upload (Pinned Notes only):**
   - **Immediate path:** in `pushRecords`, Pinned Notes leaves the blind batch for a transaction that reads the server copy, runs the same function, and writes only if no conflict is found. On success it marks the note synced; on a conflict it forks locally after the transaction.
   - **Outbox path:** in `startDraining`, add a Pinned Notes branch next to the existing Settings branch, calling the same transaction.
6. **Unchanged:** backup restore (`backup_collections.dart:858`) keeps its current merge, because a restore isn't a two-device conflict.

**Tests (`fake_cloud_firestore`, two databases standing in for two devices):**
- both devices edit the same note from the same base → both texts survive;
- edit vs. delete in each order;
- edits one after another → no fork;
- an existing row with `syncedVersion` null → no false fork;
- an edit made during an upload stays marked as not uploaded.

The existing sync tests must still pass.

## Phase 2: Encryption core (`lib/core/secure_vault/`)

1. **Add the `cryptography` package** (current 2.x).
2. **Benchmark first.** Time Argon2id at OWASP settings (19 MiB memory, 2 iterations, 1 lane) on your Windows machine and your Android phone, in release mode.
   - If either takes over ~2 s, fall back to PBKDF2-HMAC-SHA256 at 600k iterations.
   - The KDF settings live in the header, so this can change later.
   - Key derivation runs off the UI thread (`Isolate.run`).
3. **Header fields** (one Firestore document, `users/{uid}/secure_vault/header`, copied to a local one-row table):
   - `vaultId`
   - KDF name and settings, plus salt
   - `wrappedKey` (the data key encrypted with the password key), plus its nonce
   - `headerVersion`, `updatedAt`
4. **Note encryption:**
   - AES-256-GCM with a fresh 12-byte nonce on every save.
   - The extra authenticated data is `vaultId` only, not the note id. This lets a conflict fork move ciphertext to a new note id **while locked**, without the key.
5. **API:**
   - `createVault(password)`
   - `unlock(password) → key | wrongPassword`
   - `encrypt(key, text)`, `decrypt(key, box)`
   - `rewrap(key, newPassword)`
6. **Tests:**
   - encrypt/decrypt round trip;
   - the wrong password is rejected;
   - notes still decrypt after a password change;
   - nonces never repeat;
   - tampered ciphertext is rejected.

## Phase 3: Storage and sync

1. **New tables:**
   - `SecureNotesTable`: id, ciphertext, nonce, `vaultId`, createdAt, updatedAt, version, `syncedVersion`, deletedAt.
   - `SecureVaultHeaderTable`: a single row.
2. **New collection:** `FirestoreCollections.secureNotes`, added to the collection lists.
3. **Notes sync** uses Phase 1's transaction and conflict function unchanged. Conflicts are checked on ciphertext, so they work while locked.
4. **Header sync:**
   - **Creating the vault requires being online:** a transaction that fails if a header already exists. This rules out two devices each making their own vault offline.
   - **Changing the password requires being online:** a transaction that writes only if `headerVersion` still matches what this device read.
   - **Downloads:** keep the server header if its `headerVersion` is newer. Unlocking offline uses the locally cached header.
5. **Notes from an old vault are hidden.** A note whose `vaultId` doesn't match the current header is never shown. If the header's `vaultId` changes while unlocked (after a reset), the device locks.
6. **Backups, export and account-wide uploads:**
   - Add the notes and header to `buildBackupCollections`, as ciphertext only, so restores still work.
   - Add them to the full re-upload list (`remote_sync_service.dart:7320`) and the purge of expired tombstones.
   - Check that account switching and sign-out cover the new tables.

## Phase 4: UI (`notification_inbox_popover.dart`)

1. **Hidden entry point:**
   - Wrap the "Inbox" `Text` (line 228) in a `RawGestureDetector` with a 1.5 s `LongPressGestureRecognizer` and `excludeFromSemantics: true`.
   - No `MouseRegion`, so the cursor doesn't change.
   - The hold does one of three things:
     - **No vault yet:** opens the setup dialog.
     - **Vault exists and is locked:** opens the unlock dialog.
     - **Already unlocked:** locks it.
2. **Dialogs:**
   - **Fields:** obscured, with `enableSuggestions: false`, `autocorrect: false` and `enableIMEPersonalizedLearning: false`. No Vim or spellcheck.
   - **Setup:** password + confirmation, minimum 8 characters, plus a plain warning that a forgotten password means the notes are gone.
   - **Unlock:** offers a **"Reset vault"** link. It deletes every secure note and lets you create a new vault, with a typed confirmation.
3. **Session (`secureVaultSessionProvider`):** holds the data key and decrypted text in memory only.
4. **`_SecureNotesSection`:**
   - Sits between Pinned Notes and Scheduled, and is built only while unlocked.
   - Mirrors `_PinnedNotesSection`: an add field plus rows.
   - A small menu on its label offers "Change password" (current password + new password + confirmation) and "Lock".
5. **Reusing the row widget:** `_PinnedNoteRow` (line 686) gets a `secure` flag. When set, it:
   - turns off spellcheck, snippets and autocorrect (line 891 and the session at 859);
   - turns off suggestions and IME learning;
   - **keeps Vim**;
   - adds a copy button;
   - shows "Secure note deleted" in the undo toast instead of `deletedMessage(note.text)`, which would print the plaintext.
6. **Locking:**
   - **Triggers:**
     - the popover closing (`dispose`);
     - 5 minutes with no pointer or key activity in the popover (a timer reset by a `Listener` around its content and by typing);
     - sign-out.
   - **Locking clears:**
     - the key;
     - the decrypted text, controllers and undo history;
     - `VimRegister.text`, `VimRegister.pattern` and `VimRegister.linewise`.
7. **Copying:**
   - **Clearing:** after 30 s, the clipboard is cleared, but only if it still holds that text. The timer lives outside the widget, so it still fires after locking.
   - **On Windows,** the text is placed on the clipboard through `win32` (already a dependency) with the `ExcludeClipboardContentFromMonitorProcessing` format. Without this, Win+V clipboard history and cloud clipboard keep the password even after the 30 s clear.
   - **On Android,** Flutter's clipboard has no "sensitive" flag, so the keyboard's clipboard preview may show it. A native fix is a possible follow-up.

## Phase 5: Leak checks and tests

**Widget tests:**
- the long-press reveals the prompt;
- the "Inbox" title has no cursor change and no semantics action;
- the popover closing clears the Vim register;
- the clipboard is cleared at 30 s (simulated time) and left alone if it changed;
- the idle lock fires at 5 minutes.

**Codebase checks:**
- no new code logs payloads;
- search doesn't read the new table (it doesn't read Pinned Notes today either);
- no drafts are saved.

## Defaults I've assumed (say if any are wrong)

1. **Reset vault exists.** Without it, a forgotten password leaves the feature permanently unusable.
2. **Holding "Inbox" again locks the vault.**
3. **Minimum password length is 8.**
4. **Windows clipboard-history exclusion is included.**
5. **Minimizing doesn't lock** unless the popover closes, as you chose.
