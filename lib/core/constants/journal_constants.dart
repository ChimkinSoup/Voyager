/// Stable built-in journal id used locally. It may be renamed/recolored, but
/// remains the default.
const legacyJournalId = '__legacy__';

/// Firestore rejects document ids that use reserved `__` segments.
const legacyJournalFirestoreId = 'legacy-default-journal';

String journalDocumentIdForFirestore(String localId) {
  return localId == legacyJournalId ? legacyJournalFirestoreId : localId;
}

String journalDocumentIdFromFirestore(String firestoreId) {
  return firestoreId == legacyJournalFirestoreId ? legacyJournalId : firestoreId;
}

String journalReferenceIdForFirestore(String localJournalId) {
  return journalDocumentIdForFirestore(localJournalId);
}

String journalReferenceIdFromFirestore(String firestoreJournalId) {
  return journalDocumentIdFromFirestore(firestoreJournalId);
}
