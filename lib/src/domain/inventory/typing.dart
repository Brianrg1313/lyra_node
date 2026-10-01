import 'package:lyra_protocol/lyra_protocol.dart';

import '../../storage/store.dart' show fold;
import 'cells.dart';

/// The typing rules of an import (`inventory.md` I-43): the offline stand-in for the cloud's
/// AI pass. Predictable on purpose: a column is typed by its header when the header names a
/// known kind and the values agree, else by what its values look like, else it stays `TEXT`.
abstract final class Typing {
  /// How many of a column's values the rules look at.
  static const sample = 200;

  /// The share of non-empty values that must fit a type.
  static const _fit = 0.95;

  /// Header keywords, folded (lower case, no accents), in the order they are tried: a longer,
  /// more specific kind first, so "código de barras" is a barcode and not a SKU, and "nombre de
  /// categoría" a category and not a title.
  static const keywords = <(String, List<String>)>[
    (FieldTypes.barcode, ["codigo de barras", "codigo barras", "cod barras", "barcode", "bar code", "ean", "ean13", "upc", "gtin"]),
    (FieldTypes.image, ["imagen", "imagenes", "image", "images", "foto", "fotos", "photo", "photos", "picture", "pictures", "imagem", "imagens"]),
    (FieldTypes.categories, ["categoria", "categorias", "category", "categories", "rubro", "familia"]),
    (FieldTypes.description, ["descripcion", "description", "descricao", "detalle", "detalles", "detail", "details"]),
    (FieldTypes.stock, ["stock", "existencia", "existencias", "cantidad", "inventario", "qty", "quantity", "estoque", "quantidade", "unidades", "units", "on hand"]),
    (FieldTypes.price, ["precio", "price", "pvp", "preco", "valor", "importe", "costo", "cost", "custo"]),
    (FieldTypes.sku, ["sku", "codigo", "code", "cod", "ref", "referencia", "reference"]),
    (FieldTypes.title, ["nombre", "name", "producto", "product", "articulo", "item", "titulo", "title", "nome", "produto"]),
  ];

  /// The type of each column ([headers], with up to [sample] [values] each), by I-43: at most one
  /// `TITLE` and one `STOCK`, and when no header named the title, the first column left as text
  /// takes it (a product needs a name to be sold and searched by).
  static List<String> columns(List<String> headers, List<List<String>> values, {required String language}) {
    final types = [
      for (final (index, header) in headers.indexed) column(header, values[index], language: language),
    ];

    for (final single in const [FieldTypes.title, FieldTypes.stock]) {
      final first = types.indexOf(single);
      for (var i = first + 1; first != -1 && i < types.length; i++) {
        if (types[i] == single) types[i] = FieldTypes.text;
      }
    }

    if (!types.contains(FieldTypes.title)) {
      final text = types.indexOf(FieldTypes.text);
      if (text != -1) types[text] = FieldTypes.title;
    }

    return types;
  }

  /// One column's type, before the one-of rules of [columns].
  static String column(String header, List<String> values, {required String language}) {
    final filled = [for (final value in values.take(sample)) if (value.trim().isNotEmpty) value.trim()];
    final byHeader = named(header);

    if (byHeader != null && _fits(filled, (value) => fits(byHeader, value, language: language))) return byHeader;
    if (filled.isEmpty) return FieldTypes.text;

    for (final type in const [
      FieldTypes.boolean, FieldTypes.barcode, FieldTypes.number, FieldTypes.decimal,
      FieldTypes.date, FieldTypes.datetime, FieldTypes.email, FieldTypes.url,
    ]) {
      // A column of codes is a barcode only when its check digits say so: by header any code is.
      final test = type == FieldTypes.barcode ? gtin : (String value) => fits(type, value, language: language);
      if (_fits(filled, test)) return type;
    }

    return FieldTypes.text;
  }

  /// The kind [header] names, or null.
  static String? named(String header) {
    final words = _words(header);

    for (final (type, names) in keywords) {
      for (final name in names) {
        if (_contains(words, _words(name))) return type;
      }
    }

    return null;
  }

  /// Whether [value] reads as [type] (what [cell] would store without keeping it as text).
  static bool fits(String type, String value, {required String language}) => switch (type) {
    FieldTypes.stock => _count(value, language) != null,
    FieldTypes.image => value.contains("://"),
    FieldTypes.email => RegExp(r"^[^@\s]+@[^@\s]+\.[^@\s]+$").hasMatch(value),
    FieldTypes.url => RegExp(r"^(https?://|www\.)\S+$", caseSensitive: false).hasMatch(value),
    _ => cell(type, value, language: language) != null,
  };

  /// [raw] as [type] stores it, or null when it doesn't fit (the import then keeps the text,
  /// I-46). Numbers take `,` or `.` as their decimal mark, a currency sign and thousands
  /// separators; dates take `YYYY-MM-DD` or the language's day order.
  static Object? cell(String type, String raw, {required String language, int decimals = 2}) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    switch (type) {
      case FieldTypes.number:
        final amount = _amount(text, language);
        return amount == null ? null : Cells.read(type, amount);
      case FieldTypes.price || FieldTypes.currency:
        final amount = _amount(text, language);
        if (amount == null) return null;
        final value = double.parse(amount);
        return value < 0 ? null : Cells.read(type, _trim(value.toStringAsFixed(decimals)), decimals: decimals);
      case FieldTypes.decimal || FieldTypes.percentage || FieldTypes.measure || FieldTypes.discount:
        final amount = _amount(text.replaceAll("%", ""), language);
        return amount == null ? null : Cells.read(type, amount);
      case FieldTypes.boolean:
        return switch (fold(text)) {
          "true" || "si" || "yes" || "sim" || "verdadero" || "verdadeiro" || "x" => true,
          "false" || "no" || "nao" || "falso" => false,
          _ => null,
        };
      case FieldTypes.date:
        return _date(text, language);
      case FieldTypes.datetime:
        final match = RegExp(r"^(\d{4}-\d{2}-\d{2})[ T](\d{2}):(\d{2})").firstMatch(text);
        return match == null ? null : Cells.read(type, "${match[1]} ${match[2]}:${match[3]}");
      case FieldTypes.barcode:
        return text.length > 64 ? null : text;
      case FieldTypes.email || FieldTypes.url:
        return Cells.read(type, text);
      case FieldTypes.image:
        final urls = [for (final part in text.split(RegExp(r"[\s,;|]+"))) if (part.contains("://")) part];
        return urls.isEmpty ? null : urls.take(8).toList();
      case FieldTypes.categories:
        return Cells.read(type, text);
      default:
        final max = FieldTypes.long.contains(type) ? 10000 : 1000;
        return text.length > max ? text.substring(0, max) : text;
    }
  }

  /// An opening balance (I-44): a whole number of units, not negative.
  static int? units(String raw, {required String language}) => _count(raw.trim(), language);

  /// Whether [code] is an 8, 12, 13 or 14 digit GS1 code with a valid check digit.
  static bool gtin(String code) {
    if (!RegExp(r"^(\d{8}|\d{12,14})$").hasMatch(code)) return false;

    var sum = 0;
    for (var i = 0; i < code.length - 1; i++) {
      final digit = code.codeUnitAt(code.length - 2 - i) - 0x30;
      sum += i.isEven ? digit * 3 : digit;
    }

    return (10 - sum % 10) % 10 == code.codeUnitAt(code.length - 1) - 0x30;
  }

  static bool _fits(List<String> values, bool Function(String value) test) {
    if (values.isEmpty) return true;

    return values.where(test).length >= values.length * _fit;
  }

  static int? _count(String text, String language) {
    final amount = _amount(text, language);
    if (amount == null) return null;

    final value = num.parse(amount);
    return value >= 0 && value == value.truncate() && value <= 1000000 ? value.toInt() : null;
  }

  /// [text] as a number with a dot, or null. One mark that appears once is the decimal mark,
  /// except a `,` before three digits in English (`1,500`); one that repeats separates
  /// thousands; with both, the last one is the decimal mark.
  static String? _amount(String text, String language) {
    var body = text.replaceAll(RegExp(r"[\s ']"), "");
    body = body.replaceFirst(RegExp(r"^(?:[A-Za-z]{1,3}\$?|[$€£¥₡₲₱₹]|S/\.?)"), "");
    body = body.replaceFirst(RegExp(r"(?:[A-Za-z]{1,3}|[$€£¥₡₲₱₹])$"), "");
    if (!RegExp(r"^[+-]?\d[\d.,]*$").hasMatch(body)) return null;

    final negative = body.startsWith("-");
    body = body.replaceFirst(RegExp(r"^[+-]"), "");

    final dots = ".".allMatches(body).length;
    final commas = ",".allMatches(body).length;
    String number;

    if (dots > 0 && commas > 0) {
      final decimal = body.lastIndexOf(".") > body.lastIndexOf(",") ? "." : ",";
      final thousands = decimal == "." ? "," : ".";
      if (decimal.allMatches(body).length > 1) return null;
      number = body.replaceAll(thousands, "").replaceAll(",", ".");
    } else if (dots > 1 || commas > 1) {
      final mark = dots > 1 ? "." : ",";
      if (!RegExp("^\\d{1,3}(${RegExp.escape(mark)}\\d{3})+\$").hasMatch(body)) return null;
      number = body.replaceAll(mark, "");
    } else if (commas == 1) {
      number = language == "en" && RegExp(r"^\d{1,3},\d{3}$").hasMatch(body) ? body.replaceAll(",", "") : body.replaceAll(",", ".");
    } else {
      number = body;
    }

    if (!RegExp(r"^\d{1,15}(\.\d+)?$").hasMatch(number)) return null;
    if (number.contains(".")) number = _trim(number);

    return negative ? "-$number" : number;
  }

  /// `12.50` → `12.5`, `3.00` → `3`.
  static String _trim(String number) {
    if (!number.contains(".")) return number;

    final trimmed = number.replaceFirst(RegExp(r"0+$"), "");
    return trimmed.endsWith(".") ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }

  static String? _date(String text, String language) {
    final iso = RegExp(r"^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T]00:00(?::00)?)?$").firstMatch(text);
    final local = RegExp(r"^(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2}|\d{4})$").firstMatch(text);

    final (int year, int month, int day) parts;
    if (iso != null) {
      parts = (int.parse(iso[1]!), int.parse(iso[2]!), int.parse(iso[3]!));
    } else if (local != null) {
      final first = int.parse(local[1]!);
      final second = int.parse(local[2]!);
      var year = int.parse(local[3]!);
      if (local[3]!.length == 2) year += year < 70 ? 2000 : 1900;
      parts = language == "en" ? (year, first, second) : (year, second, first);
    } else {
      return null;
    }

    String two(int n) => n.toString().padLeft(2, "0");
    final value = "${parts.$1.toString().padLeft(4, "0")}-${two(parts.$2)}-${two(parts.$3)}";

    return Cells.read(FieldTypes.date, value) as String?;
  }

  static List<String> _words(String text) =>
    fold(text).split(RegExp(r"[^a-z0-9]+")).where((word) => word.isNotEmpty).toList();

  static bool _contains(List<String> words, List<String> name) {
    if (name.isEmpty || name.length > words.length) return false;

    for (var start = 0; start + name.length <= words.length; start++) {
      var match = true;
      for (var i = 0; i < name.length && match; i++) {
        match = words[start + i] == name[i];
      }
      if (match) return true;
    }

    return false;
  }
}
