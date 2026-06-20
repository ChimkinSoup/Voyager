import 'package:voyager/core/utils/ids.dart';

class SoftDeletable {
  const SoftDeletable({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  SoftDeletable copyWithDeleted(DateTime? deletedAt) {
    return SoftDeletable(
      id: id,
      createdAt: createdAt,
      updatedAt: utcNow(),
      deletedAt: deletedAt,
    );
  }
}
