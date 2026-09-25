import 'package:voyager/domain/models/finance_models.dart';

/// The in-page filter behind the finance ledger's Ctrl+F search bar. Pure so
/// the matching rules can be tested without pumping the page.

/// The lowercased tokens of [query]. Every one of them has to match somewhere
/// in a transaction for it to be a result. A bare `#` asks for no tag yet, and
/// a bare `$`, `-` or `+` for no amount yet, so they are dropped rather than
/// matching every tagged row or none at all.
List<String> financeSearchTokens(String query) => query
    .toLowerCase()
    .split(RegExp(r'\s+'))
    .where((token) => token.isNotEmpty && !_bareMarkerPattern.hasMatch(token))
    .toList(growable: false);

/// A token made only of the `#`, `$` and sign markers that start a tag or an
/// amount still being typed.
final _bareMarkerPattern = RegExp(r'^[#$+-]+$');

/// A token that reads as an amount once `$`, thousands separators and a
/// leading sign are dropped.
final _amountPattern = RegExp(r'^\d+(\.\d{0,2})?$');

/// Whether [transaction] survives a filter of [tokens], which must already be
/// folded by [financeSearchTokens].
///
/// Each token matches one of three ways:
/// - `#groc` matches a tag starting with `groc`, and nothing else.
/// - Plain text matches anywhere in the origin, the note or a tag.
/// - A number also matches the start of the amount: `12` finds $12.00, $12.99
///   and $120.40; `12.5` finds $12.50 to $12.59.
bool financeTransactionMatches(
  FinancialTransaction transaction,
  List<String> tokens,
) {
  if (tokens.isEmpty) return true;
  final tags = [for (final tag in transaction.tags) tag.toLowerCase()];
  // Newline-joined so a token can't match across the end of one field and the
  // start of the next.
  final text = [
    transaction.origin ?? '',
    transaction.note ?? '',
    ...tags,
  ].join('\n').toLowerCase();
  final cents = transaction.amountCents;
  final amount = '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';
  return tokens.every((token) {
    if (token.startsWith('#')) {
      final prefix = token.substring(1);
      return tags.any((tag) => tag.startsWith(prefix));
    }
    if (text.contains(token)) return true;
    final number = token
        .replaceAll(RegExp(r'[$,]'), '')
        .replaceFirst(RegExp(r'^[+-]'), '');
    return _amountPattern.hasMatch(number) && amount.startsWith(number);
  });
}
