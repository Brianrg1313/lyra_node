import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml_events.dart';

import '../../failure.dart';

/// A spreadsheet read for an import (`inventory.md` I-40, I-41): its header names and the data
/// rows under them, every cell as the text it shows (an `.xlsx` date as `YYYY-MM-DD`, a number in
/// its shortest form). Empty rows are dropped.
final class Sheet {
  const Sheet(this.headers, this.rows);

  final List<String> headers;
  final List<List<String>> rows;

  /// Data rows past which a file is `too_large` (I-40).
  static const maxRows = 50000;

  /// Columns past which a file is `too_large`: a table this wide is not a product list.
  static const maxColumns = 250;

  /// The longest a header name is kept (a field name's limit).
  static const maxHeader = 60;

  /// The uncompressed size of an `.xlsx` part past which it isn't read: a 20 MB zip can inflate
  /// to gigabytes, and the engine reads the part in memory.
  static const maxPart = 256 << 20;

  /// [bytes] read as [format] (`csv` or `excel`, the app's `ImportFormat`), with the header on
  /// the 1-based [row]. Off the server's isolate: a 20 MB file takes seconds. Throws
  /// `unsupported_file`, `empty_file` or `too_large`.
  static Future<Sheet> read(Uint8List bytes, String format, int row) async {
    if (format != "csv" && format != "excel") throw const EngineFailure("unsupported_file");
    if (row < 1) throw const EngineFailure("invalid_field", {"field": "row"});

    final (outcome, headers, rows) = await Isolate.run(() => _parse(bytes, format, row));
    if (outcome != null) throw EngineFailure(outcome);

    return Sheet(headers, rows);
  }

  /// Runs inside the isolate: answers the failure code, or the sheet as plain lists (what crosses
  /// an isolate without copying classes).
  static (String?, List<String>, List<List<String>>) _parse(Uint8List bytes, String format, int row) {
    final List<List<String>> grid;
    try {
      grid = format == "csv" ? Csv.parse(Csv.decode(bytes)) : Xlsx.parse(bytes);
    } on EngineFailure catch (failure) {
      return (failure.code, const [], const []);
    } on Object {
      return ("unsupported_file", const [], const []);
    }

    if (grid.length < row) return ("empty_file", const [], const []);

    final data = [
      for (final cells in grid.skip(row))
        if (cells.any((cell) => cell.trim().isNotEmpty)) cells,
    ];
    if (data.length > maxRows) return ("too_large", const [], const []);

    final header = grid[row - 1];
    var width = _lastFilled(header);
    for (final cells in data.take(200)) {
      final last = _lastFilled(cells);
      if (last > width) width = last;
    }
    if (width == 0) return ("empty_file", const [], const []);
    if (width > maxColumns) return ("too_large", const [], const []);

    return (null, names([for (var i = 0; i < width; i++) i < header.length ? header[i] : ""]), [
      for (final cells in data) [for (var i = 0; i < width; i++) i < cells.length ? cells[i].trim() : ""],
    ]);
  }

  /// The header row's names (I-41): trimmed and cut to [maxHeader], an empty one `Column N`, a
  /// repeated one (without case) with ` (2)`, ` (3)`.
  static List<String> names(List<String> header) {
    final taken = <String>{};
    final out = <String>[];

    for (final (index, raw) in header.indexed) {
      var base = raw.replaceAll(RegExp(r"\s+"), " ").trim();
      if (base.isEmpty) base = "Column ${index + 1}";
      if (base.length > maxHeader) base = base.substring(0, maxHeader).trim();

      var name = base;
      for (var copy = 2; taken.contains(name.toLowerCase()); copy++) {
        final suffix = " ($copy)";
        name = (base.length + suffix.length > maxHeader ? base.substring(0, maxHeader - suffix.length) : base) + suffix;
      }
      taken.add(name.toLowerCase());
      out.add(name);
    }

    return out;
  }

  static int _lastFilled(List<String> cells) {
    for (var i = cells.length; i > 0; i--) {
      if (cells[i - 1].trim().isNotEmpty) return i;
    }

    return 0;
  }
}

/// A `.csv` (I-40): UTF-8, UTF-16 with its BOM, or Windows-1252 (what Excel saves in a Spanish
/// or Portuguese Windows) when the bytes aren't UTF-8; the separator is `,`, `;` or tab,
/// whichever the first lines use most outside quotes. Quotes follow RFC 4180.
abstract final class Csv {
  static String decode(Uint8List bytes) {
    if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) return _utf16(bytes, 2, little: true);
    if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) return _utf16(bytes, 2, little: false);

    final start = bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf ? 3 : 0;
    try {
      return utf8.decode(Uint8List.sublistView(bytes, start));
    } on FormatException {
      return String.fromCharCodes([for (final byte in bytes) _cp1252[byte] ?? byte]);
    }
  }

  static List<List<String>> parse(String text) {
    final separator = _separator(text);
    final rows = <List<String>>[];
    var row = <String>[];
    final cell = StringBuffer();
    var quoted = false;
    var i = 0;

    void endCell() {
      row.add(cell.toString());
      cell.clear();
    }

    void endRow() {
      endCell();
      rows.add(row);
      row = <String>[];
    }

    while (i < text.length) {
      final char = text[i];

      if (quoted) {
        if (char == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          cell.write(char);
        }
      } else if (char == '"' && cell.isEmpty) {
        quoted = true;
      } else if (char == separator) {
        endCell();
      } else if (char == "\r" || char == "\n") {
        if (char == "\r" && i + 1 < text.length && text[i + 1] == "\n") i++;
        endRow();
      } else {
        cell.write(char);
      }
      i++;
    }

    if (cell.isNotEmpty || row.isNotEmpty) endRow();

    return rows;
  }

  static String _separator(String text) {
    final counts = {",": 0, ";": 0, "\t": 0};
    var quoted = false;
    var lines = 0;

    for (var i = 0; i < text.length && lines < 20; i++) {
      final char = text[i];
      if (char == '"') quoted = !quoted;
      if (quoted) continue;
      if (char == "\n") lines++;
      if (counts.containsKey(char)) counts[char] = counts[char]! + 1;
    }

    return counts.entries.reduce((best, entry) => entry.value > best.value ? entry : best).key;
  }

  static String _utf16(Uint8List bytes, int start, {required bool little}) {
    final units = <int>[];
    for (var i = start; i + 1 < bytes.length; i += 2) {
      units.add(little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1]);
    }

    return String.fromCharCodes(units);
  }

  /// Windows-1252's bytes 0x80–0x9F that aren't Latin-1's.
  static const _cp1252 = {
    0x80: 0x20ac, 0x82: 0x201a, 0x83: 0x0192, 0x84: 0x201e, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
    0x88: 0x02c6, 0x89: 0x2030, 0x8a: 0x0160, 0x8b: 0x2039, 0x8c: 0x0152, 0x8e: 0x017d, 0x91: 0x2018,
    0x92: 0x2019, 0x93: 0x201c, 0x94: 0x201d, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02dc,
    0x99: 0x2122, 0x9a: 0x0161, 0x9b: 0x203a, 0x9c: 0x0153, 0x9e: 0x017e, 0x9f: 0x0178,
  };
}

/// The first sheet of an `.xlsx` (Office Open XML), read with an event parser so a big sheet
/// is never a DOM. Shared strings, inline strings, booleans and numbers are read; a number in a
/// date format becomes `YYYY-MM-DD` (`YYYY-MM-DD HH:mm` with a time); an error cell is empty.
abstract final class Xlsx {
  static List<List<String>> parse(Uint8List bytes) {
    final zip = ZipDecoder().decodeBytes(bytes);

    String? part(String name) {
      final file = zip.findFile(name);
      if (file == null) return null;
      if (file.size > Sheet.maxPart) throw const EngineFailure("too_large");

      return utf8.decode(file.content, allowMalformed: true);
    }

    final workbook = part("xl/workbook.xml") ?? (throw const EngineFailure("unsupported_file"));
    final sheet = part(_firstSheet(workbook, part("xl/_rels/workbook.xml.rels"))) ??
      (throw const EngineFailure("unsupported_file"));
    final strings = _strings(part("xl/sharedStrings.xml"));
    final dates = _dateStyles(part("xl/styles.xml"));
    final base1904 = RegExp(r'date1904="(1|true)"').hasMatch(workbook);

    return _cells(sheet, strings, dates, base1904);
  }

  /// The path of the workbook's first sheet, through its relationship id.
  static String _firstSheet(String workbook, String? rels) {
    String? id;
    for (final event in parseEvents(workbook)) {
      if (event is XmlStartElementEvent && _local(event.name) == "sheet") {
        id = _attribute(event, "id");
        break;
      }
    }

    if (id != null && rels != null) {
      for (final event in parseEvents(rels)) {
        if (event is XmlStartElementEvent && _local(event.name) == "Relationship" && _attribute(event, "Id") == id) {
          final target = _attribute(event, "Target") ?? "";
          if (target.startsWith("/")) return target.substring(1);

          return "xl/$target";
        }
      }
    }

    return "xl/worksheets/sheet1.xml";
  }

  static List<String> _strings(String? xml) {
    if (xml == null) return const [];

    final strings = <String>[];
    final text = StringBuffer();
    var depthT = 0;
    var phonetic = false;

    for (final event in parseEvents(xml)) {
      switch (event) {
        case XmlStartElementEvent(name: final name, isSelfClosing: final closed):
          switch (_local(name)) {
            case "si":
              text.clear();
              if (closed) strings.add("");
            case "rPh":
              phonetic = !closed;
            case "t":
              if (!closed) depthT++;
          }
        case XmlEndElementEvent(name: final name):
          switch (_local(name)) {
            case "si":
              strings.add(text.toString());
            case "rPh":
              phonetic = false;
            case "t":
              depthT--;
          }
        case XmlTextEvent(value: final value) when depthT > 0 && !phonetic:
          text.write(value);
        case XmlCDATAEvent(value: final value) when depthT > 0 && !phonetic:
          text.write(value);
        default:
          break;
      }
    }

    return strings;
  }

  /// Which cell styles (`s`, an index into `cellXfs`) show a date, and whether with a time.
  static Map<int, bool> _dateStyles(String? xml) {
    if (xml == null) return const {};

    final custom = <int, String>{};
    final styles = <int, bool>{};
    var inXfs = false;
    var index = 0;

    for (final event in parseEvents(xml)) {
      if (event is XmlStartElementEvent) {
        switch (_local(event.name)) {
          case "numFmt":
            final id = int.tryParse(_attribute(event, "numFmtId") ?? "");
            if (id != null) custom[id] = _attribute(event, "formatCode") ?? "";
          case "cellXfs":
            inXfs = !event.isSelfClosing;
          case "xf" when inXfs:
            final id = int.tryParse(_attribute(event, "numFmtId") ?? "") ?? 0;
            final time = _dateFormat(id, custom[id]);
            if (time != null) styles[index] = time;
            index++;
        }
      } else if (event is XmlEndElementEvent && _local(event.name) == "cellXfs") {
        inXfs = false;
      }
    }

    return styles;
  }

  /// Null when number format [id] isn't a date; whether it shows a time when it is.
  static bool? _dateFormat(int id, String? code) {
    if (id >= 14 && id <= 17 || id >= 27 && id <= 31 || id >= 34 && id <= 36 || id >= 50 && id <= 58) return false;
    if (id == 18 || id == 19 || id == 20 || id == 21 || id == 22 || id == 32 || id == 33 || id == 45 || id == 46 || id == 47) {
      return id == 22;
    }
    if (code == null) return null;

    // Quoted text, escapes and [colors] / [$-locale] are not the pattern.
    final pattern = code.replaceAll(RegExp(r'"[^"]*"|\\.|\[[^\]]*\]'), "").toLowerCase();
    if (!RegExp(r"[dy]").hasMatch(pattern)) return null;

    return RegExp(r"h").hasMatch(pattern);
  }

  static List<List<String>> _cells(String xml, List<String> strings, Map<int, bool> dates, bool base1904) {
    final grid = <List<String>>[];
    List<String>? row;
    var nextRow = 1;
    var nextColumn = 0;
    var column = 0;
    String? type;
    int? style;
    final value = StringBuffer();
    var reading = false;

    for (final event in parseEvents(xml)) {
      switch (event) {
        case XmlStartElementEvent(name: final name, isSelfClosing: final closed):
          switch (_local(name)) {
            case "row":
              final number = int.tryParse(_attribute(event, "r") ?? "") ?? nextRow;
              while (grid.length < number - 1) {
                grid.add(<String>[]);
              }
              row = <String>[];
              grid.add(row);
              nextRow = number + 1;
              nextColumn = 0;
              if (closed) row = null;
              if (grid.length > Sheet.maxRows + 1000) throw const EngineFailure("too_large");
            case "c" when row != null:
              final reference = _attribute(event, "r");
              column = reference == null ? nextColumn : _column(reference);
              nextColumn = column + 1;
              type = _attribute(event, "t");
              style = int.tryParse(_attribute(event, "s") ?? "");
              value.clear();
            case "v" || "t" when row != null && !closed:
              reading = true;
          }
        case XmlEndElementEvent(name: final name):
          switch (_local(name)) {
            case "v" || "t":
              reading = false;
            case "c" when row != null:
              if (column >= Sheet.maxColumns * 4) break;
              while (row.length <= column) {
                row.add("");
              }
              row[column] = _value(type, style, value.toString(), strings, dates, base1904);
            case "row":
              row = null;
          }
        case XmlTextEvent(value: final text) when reading:
          value.write(text);
        case XmlCDATAEvent(value: final text) when reading:
          value.write(text);
        default:
          break;
      }
    }

    return grid;
  }

  static String _value(String? type, int? style, String raw, List<String> strings, Map<int, bool> dates, bool base1904) {
    switch (type) {
      case "s":
        final index = int.tryParse(raw.trim());
        return index != null && index >= 0 && index < strings.length ? strings[index] : "";
      case "b":
        return raw.trim() == "1" ? "true" : "false";
      case "e":
        return "";
      case "str" || "inlineStr":
        return raw;
      case "d":
        return raw.length >= 10 ? raw.substring(0, raw.contains("T00:00:00") ? 10 : raw.length) : raw;
    }

    final number = double.tryParse(raw.trim());
    if (number == null) return raw.trim();

    final time = style == null ? null : dates[style];
    if (time != null) return _date(number, withTime: time, base1904: base1904);

    return shortest(number);
  }

  /// A spreadsheet number in its shortest text: an integer without `.0`, and the float noise
  /// a binary double leaves (`12.300000000000001`) rounded off at 8 places.
  static String shortest(double value) {
    if (value == value.truncateToDouble() && value.abs() < 1e15) return value.toInt().toString();

    var text = value.toStringAsFixed(8);
    text = text.replaceFirst(RegExp(r"0+$"), "");

    return text.endsWith(".") ? text.substring(0, text.length - 1) : text;
  }

  /// An Excel serial day as `YYYY-MM-DD` (with ` HH:mm` when [withTime]). Day 60 of the 1900
  /// system is the leap day 1900 never had; serials past it count from 1899-12-30.
  static String _date(double serial, {required bool withTime, required bool base1904}) {
    final origin = base1904 ? DateTime.utc(1904) : DateTime.utc(1899, 12, serial < 60 ? 31 : 30);
    final minutes = (serial * 24 * 60).round();
    final at = origin.add(Duration(minutes: minutes));
    String two(int n) => n.toString().padLeft(2, "0");
    final day = "${at.year.toString().padLeft(4, "0")}-${two(at.month)}-${two(at.day)}";

    return withTime ? "$day ${two(at.hour)}:${two(at.minute)}" : day;
  }

  /// `B3` → 1 (0-based column).
  static int _column(String reference) {
    var column = 0;
    for (final unit in reference.toUpperCase().codeUnits) {
      if (unit < 0x41 || unit > 0x5a) break;
      column = column * 26 + unit - 0x40;
    }

    return column - 1;
  }

  static String _local(String name) {
    final colon = name.indexOf(":");
    return colon == -1 ? name : name.substring(colon + 1);
  }

  static String? _attribute(XmlStartElementEvent event, String name) {
    for (final attribute in event.attributes) {
      if (_local(attribute.name) == name) return attribute.value;
    }

    return null;
  }
}
