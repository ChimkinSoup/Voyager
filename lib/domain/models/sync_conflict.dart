class SyncConflict {
  const SyncConflict({
    required this.id,
    required this.collection,
    required this.documentId,
    required this.localPayloadJson,
    required this.remotePayloadJson,
    required this.detectedAt,
    this.localTitle,
    this.remoteTitle,
    this.localText,
    this.remoteText,
  });

  final String id;
  final String collection;
  final String documentId;
  final String localPayloadJson;
  final String remotePayloadJson;
  final DateTime detectedAt;
  final String? localTitle;
  final String? remoteTitle;
  final String? localText;
  final String? remoteText;
}
