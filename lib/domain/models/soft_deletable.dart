import 'package:voyager/core/utils/ids.dart';

class SoftDeletable {
  const SoftDeletable({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    this.version = 0,
    this.deletedAt,
  });

  final String id;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int version;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  SoftDeletable copyWithDeleted(DateTime? deletedAt) {
    return SoftDeletable(
      id: id,
      createdAt: createdAt,
      updatedAt: utcNow(),
      version: version + 1,
      deletedAt: deletedAt,
    );
  }
}
