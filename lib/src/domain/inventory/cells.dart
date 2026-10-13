import 'package:lyra_protocol/lyra_protocol.dart';

import '../../failure.dart';

/// What a cell stores for a written value, by field type (`inventory.md` I-21).
///
/// The app writes every cell as the text the person typed (`"22.50"`, `"true"`, `"a, b"`); the
/// cell keeps it in its type (a number, a bool, a list) so the sheet and the POS read it back
/// without guessing.
abstract final class Cells {
  static const _shortText = 1000;
  static const _longText = 10000;

  /// [raw] checked for a field of [type]; null clears the cell (`null` or `""`, I-20).
  /// [decimals] is how many a price may carry (its currency's). Throws `invalid_value` naming
  /// [field], or `read_only_field` for a cell only the engine writes (I-10, images).
  static Object? check(String type, Object? raw, {required String field, int decimals = 2}) {
    if (FieldTypes.readOnly.contains(type) || type == FieldTypes.image) {
      throw EngineFailure("read_only_field", {"field": field});
    }
    if (raw == null || raw is String && raw.trim().isEmpty) return null;

    final value = read(type, raw, decimals: decimals);
    if (value == null) throw EngineFailure("invalid_value", {"field": field});

    return value;
  }

  /// [raw] in [type], or null when it doesn't fit. A type change re-reads stored values with
  /// this and keeps the ones that don't fit as text (I-14).
  static Object? read(String type, Object raw, {int decimals = 2}) {
    final text = raw is List ? raw.join(", ") : raw.toString().trim();

    switch (type) {
      case FieldTypes.number:
        final number = raw is num ? raw : num.tryParse(text);
        return number != null && number == number.truncate() && number.abs() < 1e15 ? number.toInt() : null;
      case FieldTypes.decimal || FieldTypes.percentage || FieldTypes.measure:
        return _decimal(text);
      case FieldTypes.discount:
        final value = _decimal(text);
        return value != null && num.parse(value) >= 0 && num.parse(value) <= 100 ? value : null;
      case FieldTypes.price || FieldTypes.currency:
        final value = _decimal(text);
        if (value == null || num.parse(value) < 0) return null;
        final dot = value.indexOf(".");
        return dot == -1 || value.length - dot - 1 <= decimals ? value : null;
      case FieldTypes.boolean:
        return switch (raw is bool ? "$raw" : text.toLowerCase()) {
          "true" || "1" => true,
          "false" || "0" => false,
          _ => null,
        };
      case FieldTypes.date:
        return _day(text) ? text : null;
      case FieldTypes.datetime:
        return _instant(text) ? text : null;
      case FieldTypes.categories || FieldTypes.sizes:
        final labels = raw is List
          ? [for (final label in raw) "$label".trim()]
          : text.split(RegExp(r"[,;|]")).map((label) => label.trim()).toList();
        final kept = labels.where((label) => label.isNotEmpty).toList();
        return kept.isEmpty || kept.any((label) => label.length > _shortText) ? null : kept;
      default:
        return text.length > (FieldTypes.long.contains(type) ? _longText : _shortText) ? null : text;
    }
  }

  /// A stored value as the text it came from, for a type change (I-14).
  static String asText(Object? value) => switch (value) {
    null => "",
    final List list => list.join(", "),
    _ => value.toString(),
  };

  /// A number with a dot as the separator, kept as its text so no binary rounding touches a
  /// price (README, money).
  static String? _decimal(String text) {
    if (!RegExp(r"^-?\d{1,15}(\.\d{1,8})?$").hasMatch(text)) return null;

    return text;
  }

  static bool _day(String text) {
    final match = RegExp(r"^(\d{4})-(\d{2})-(\d{2})$").firstMatch(text);
    if (match == null) return false;

    final day = DateTime.utc(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));

    return day.month == int.parse(match[2]!) && day.day == int.parse(match[3]!);
  }

  /// The app's `2026-02-12 12:30` or an ISO instant.
  static bool _instant(String text) =>
    RegExp(r"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}").hasMatch(text) && _day(text.substring(0, 10)) && DateTime.tryParse(text) != null;
}
