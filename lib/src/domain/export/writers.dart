import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// An amount in minor units of a currency with [decimals]: written as a decimal number, never
/// through a double (M-63).
final class Decimal {
  const Decimal(this.minor, this.decimals);

  final int minor;
  final int decimals;

  /// `12345` with 2 decimals → `123.45`; [mark] is the decimal mark.
  String text([String mark = "."]) {
    final digits = minor.abs().toString().padLeft(decimals + 1, "0");
    final whole = digits.substring(0, digits.length - decimals);
    final sign = minor < 0 ? "-" : "";

    return decimals == 0 ? "$sign$whole" : "$sign$whole$mark${digits.substring(digits.length - decimals)}";
  }
}

/// One dataset of an export (M-61): its stable [name] (the file or sheet), its [columns] and its
/// rows. A cell is a [String], an [int], a [bool], a [Decimal] or null.
final class Dataset {
  const Dataset(this.name, this.columns, this.rows);

  final String name;
  final List<String> columns;
  final List<List<Object?>> rows;
}

/// The two formats `export.accounting` answers (M-60).
enum ExportFormat {
  csv("application/zip", "zip"),
  xlsx("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "xlsx");

  const ExportFormat(this.contentType, this.extension);

  final String contentType;
  final String extension;

  static ExportFormat? byName(Object? raw) {
    for (final format in values) {
      if (format.name == raw) return format;
    }

    return null;
  }

  /// [datasets] as this format's bytes. [decimalComma]: the company language writes `1,5`.
  Uint8List encode(List<Dataset> datasets, {required bool decimalComma}) {
    if (this == xlsx) return Workbook.encode(datasets);

    final archive = Archive();
    for (final dataset in datasets) {
      archive.addFile(ArchiveFile.bytes("${dataset.name}.csv", CsvWriter.encode(dataset, decimalComma: decimalComma)));
    }

    return ZipEncoder().encodeBytes(archive);
  }
}

/// A dataset as CSV (M-63): UTF-8 with a BOM, CRLF, `;` between cells when the decimal mark is a
/// comma, else `,`; quoted only when a cell needs it.
abstract final class CsvWriter {
  static Uint8List encode(Dataset dataset, {required bool decimalComma}) {
    final separator = decimalComma ? ";" : ",";
    final mark = decimalComma ? "," : ".";
    final out = StringBuffer(String.fromCharCode(0xfeff));

    void line(List<Object?> cells) {
      out
        ..writeAll([for (final cell in cells) _cell(cell, separator, mark)], separator)
        ..write("\r\n");
    }

    line(dataset.columns);
    dataset.rows.forEach(line);

    return utf8.encode(out.toString());
  }

  static String _cell(Object? cell, String separator, String mark) => switch (cell) {
    null => "",
    final Decimal amount => amount.text(mark),
    final int number => "$number",
    final bool flag => "$flag",
    final String text => _text(text, separator),
    _ => _text("$cell", separator),
  };

  /// A text cell. One that a spreadsheet would run as a formula (`=`, `+`, `-`, `@` first) gets a
  /// leading `'`: a note typed at the till must never execute on the accountant's computer.
  static String _text(String text, String separator) {
    final safe = text.isNotEmpty && "=+-@\t\r".contains(text[0]) ? "'$text" : text;
    final quoted = safe.contains(separator) || safe.contains('"') || safe.contains("\n") || safe.contains("\r");

    return quoted ? '"${safe.replaceAll('"', '""')}"' : safe;
  }
}

/// Datasets as an Office Open XML workbook, one sheet each (M-61). Text goes inline, so a cell is
/// never read as a formula; an amount is a number with its currency's decimals as its format.
abstract final class Workbook {
  /// Number formats by decimals: the built-in `0` and `0.00`, the rest declared in the styles.
  static const _formats = {0: 1, 1: 164, 2: 2, 3: 165, 4: 166};

  static Uint8List encode(List<Dataset> datasets) {
    final archive = Archive();
    void add(String name, String content) => archive.addFile(ArchiveFile.bytes(name, utf8.encode(content)));

    add("[Content_Types].xml", _xml(
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/xl/workbook.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      '<Override PartName="/xl/styles.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
      '${[
        for (var i = 1; i <= datasets.length; i++)
          '<Override PartName="/xl/worksheets/sheet$i.xml" '
          'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>',
      ].join()}'
      '</Types>',
    ));
    add("_rels/.rels", _xml(
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
      'Target="xl/workbook.xml"/>'
      '</Relationships>',
    ));
    add("xl/workbook.xml", _xml(
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
      '${[
        for (var i = 1; i <= datasets.length; i++)
          '<sheet name="${_escape(datasets[i - 1].name)}" sheetId="$i" r:id="rId$i"/>',
      ].join()}'
      '</sheets></workbook>',
    ));
    add("xl/_rels/workbook.xml.rels", _xml(
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '${[
        for (var i = 1; i <= datasets.length; i++)
          '<Relationship Id="rId$i" '
          'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
          'Target="worksheets/sheet$i.xml"/>',
      ].join()}'
      '<Relationship Id="rId${datasets.length + 1}" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
      '</Relationships>',
    ));
    add("xl/styles.xml", _xml(
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<numFmts count="3"><numFmt numFmtId="164" formatCode="0.0"/><numFmt numFmtId="165" formatCode="0.000"/>'
      '<numFmt numFmtId="166" formatCode="0.0000"/></numFmts>'
      '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'
      '<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
      '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
      '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      '<cellXfs count="${2 + _formats.length}">'
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
      '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
      '${[
        for (final id in _formats.values)
          '<xf numFmtId="$id" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>',
      ].join()}'
      '</cellXfs></styleSheet>',
    ));

    for (var i = 0; i < datasets.length; i++) {
      add("xl/worksheets/sheet${i + 1}.xml", _sheet(datasets[i]));
    }

    return ZipEncoder().encodeBytes(archive);
  }

  static String _sheet(Dataset dataset) {
    final out = StringBuffer(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      // The header row stays in view while scrolling.
      '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" '
      'state="frozen"/></sheetView></sheetViews><sheetData>',
    );

    void row(int number, List<Object?> cells, {bool header = false}) {
      out.write('<row r="$number">');
      for (var column = 0; column < cells.length; column++) {
        final cell = cells[column];
        if (cell == null) continue;

        final reference = "${_column(column)}$number";
        switch (cell) {
          case final Decimal amount:
            out.write('<c r="$reference" s="${2 + _formats.keys.toList().indexOf(amount.decimals.clamp(0, 4))}">'
              '<v>${amount.text()}</v></c>');
          case final int number:
            out.write('<c r="$reference"><v>$number</v></c>');
          case final bool flag:
            out.write('<c r="$reference" t="b"><v>${flag ? 1 : 0}</v></c>');
          default:
            out.write('<c r="$reference" t="inlineStr"${header ? ' s="1"' : ""}><is><t xml:space="preserve">'
              '${_escape("$cell")}</t></is></c>');
        }
      }
      out.write("</row>");
    }

    row(1, dataset.columns, header: true);
    for (var i = 0; i < dataset.rows.length; i++) {
      row(i + 2, dataset.rows[i]);
    }

    out.write("</sheetData></worksheet>");

    return out.toString();
  }

  /// `0` → `A`, `26` → `AA`.
  static String _column(int index) {
    var name = "";
    for (var n = index + 1; n > 0; n = (n - 1) ~/ 26) {
      name = String.fromCharCode(65 + (n - 1) % 26) + name;
    }

    return name;
  }

  static String _xml(String body) => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>$body';

  /// XML text: the five entities escaped, and the control characters XML 1.0 can't hold dropped.
  static String _escape(String text) => text
    .replaceAll(RegExp(r"[\x00-\x08\x0B\x0C\x0E-\x1F]"), "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}
