/// Stable built-in calendar id used locally. It may be renamed/recolored, but
/// remains the default and cannot be deleted.
const legacyCalendarId = '__legacy_calendar__';

/// Firestore rejects document ids that use reserved `__` segments.
///
/// Calendars were local-only when [legacyCalendarId] was chosen, so the shape
/// cost nothing. They sync now, and every upload of the default calendar was
/// being rejected with `invalid-argument` and parked on the outbox — the same
/// problem journals and to-do lists solved with the same alias.
const legacyCalendarFirestoreId = 'legacy-default-calendar';

String calendarDocumentIdForFirestore(String localId) {
  return localId == legacyCalendarId ? legacyCalendarFirestoreId : localId;
}

String calendarDocumentIdFromFirestore(String firestoreId) {
  return firestoreId == legacyCalendarFirestoreId
      ? legacyCalendarId
      : firestoreId;
}

/// The calendar an event points at, as it travels to and from Firestore.
///
/// A field value rather than a document id, so the reserved shape was never
/// rejected here — events synced before the alias existed carry the raw
/// [legacyCalendarId]. [calendarDocumentIdFromFirestore] passes anything it
/// does not recognise straight through, so both spellings still resolve.
String calendarReferenceIdForFirestore(String localCalendarId) {
  return calendarDocumentIdForFirestore(localCalendarId);
}

String calendarReferenceIdFromFirestore(String firestoreCalendarId) {
  return calendarDocumentIdFromFirestore(firestoreCalendarId);
}
