/// Stable built-in to-do list id used locally. It may be renamed/recolored, but
/// remains the default and cannot be deleted.
const legacyTodoListId = '__legacy_todo__';

/// Firestore rejects document ids that use reserved `__` segments.
const legacyTodoListFirestoreId = 'legacy-default-todo-list';

String todoListDocumentIdForFirestore(String localId) {
  return localId == legacyTodoListId ? legacyTodoListFirestoreId : localId;
}

String todoListDocumentIdFromFirestore(String firestoreId) {
  return firestoreId == legacyTodoListFirestoreId ? legacyTodoListId : firestoreId;
}
