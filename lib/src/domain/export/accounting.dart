import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../audit/audit_log.dart';
import '../../failure.dart';
import '../../net/files.dart';
import '../../storage/store.dart';
import '../business/business.dart';
import '../business/zones.dart';
import '../money/finance.dart';
import '../pos/money.dart';
import '../pos/pos.dart';
import 'writers.dart';

/// `export.accounting` (`money.md` M-60 to M-65, plan §8.5): Lyra hands its data to the
/// accounting software instead of being one.
///
/// It **reads what is stored and computes nothing new**: a ticket's figures are added up from
/// its frozen lines as everywhere else (POS-20), a receivable is measured from its settlements
/// (M-30). Every row carries its Lyra `id` so a re-export matches on the other side (M-62), and
/// nothing is left out for its status (M-64). The columns are listed in `docs/export.md`; a new
/// one only ever goes **at the end** (M-61).
final class Accounting {
  Accounting(this._store, this._business, this._finance, this._files, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final Store _store;
  final Business _business;
  final Finance _finance;
  final FileStore _files;
  final DateTime Function() _now;

  Database get _db => _store.db;

  static final _day = RegExp(r"^(\d{4})-(\d{2})-(\d{2})$");

  /// The languages that write `1,5`: their CSV separates cells with `;` (M-63).
  static const _decimalComma = {"es", "pt", "fr", "it", "de"};

  static const salesColumns = [
    "id", "ticket", "status", "opened", "closed", "cancelled", "device", "seller", "closed_by", "cancelled_by",
    "payment_method", "payment_method_name", "payment_reference", "credit", "lines", "units", "subtotal", "tax",
    "total", "currency", "note",
  ];
  static const saleLinesColumns = [
    "id", "sale_id", "ticket", "sale_status", "line", "product_id", "sku", "name", "quantity", "unit_price",
    "list_price", "discount_percent", "tax_rate", "subtotal", "tax", "total", "currency",
  ];
  static const paymentsColumns = [
    "id", "date", "recorded_at", "direction", "concept", "concept_name", "amount", "currency", "method",
    "method_name", "account", "reference", "counterpart_name", "counterpart_contact", "ticket", "sale_id", "note",
    "status", "registered_by", "voided_at", "voided_by", "void_reason",
  ];
  static const receivablesColumns = [
    "id", "ticket", "date", "seller", "total", "collected", "outstanding", "currency",
  ];
  static const stockMovementsColumns = [
    "id", "at", "operation", "reason", "quantity", "on_hand_change", "product_id", "sku", "product_name", "table_id",
    "sale_id", "ticket", "source", "actor", "device", "note",
  ];

  /// `export.accounting {from, to, datasets, format}`: the file, kept for its asker
  /// ([AccountingExport.lifetime]), and the export in the audit log (M-65).
  Future<Map<String, Object?>> run(Map<String, Object?> args, {required String actor, String? device}) async {
    final from = _date(args["from"], "from");
    final to = _date(args["to"], "to");
    if (from.isAfter(to)) throw const EngineFailure("invalid_range");

    final format = ExportFormat.byName(args["format"]);
    if (format == null) throw const EngineFailure(ErrorCodes.invalidField, {"field": "format"});

    final asked = args["datasets"];
    if (asked is! List || asked.isEmpty || asked.any((name) => !AccountingExport.datasets.contains(name))) {
      throw const EngineFailure(ErrorCodes.invalidField, {"field": "datasets"});
    }
    final names = [for (final name in AccountingExport.datasets) if (asked.contains(name)) name];

    // Calendar days in the company's zone, both included: [start, end).
    final zone = _business.timezone;
    final start = _instant(Zones.startOf(zone, from.year, from.month, from.day));
    final end = _instant(Zones.startOf(zone, to.year, to.month, to.day + 1));

    final rows = names.fold<int>(0, (sum, name) => sum + _count(name, start, end));
    if (rows > AccountingExport.maxRows) {
      throw const EngineFailure("too_many_rows", {"max": AccountingExport.maxRows});
    }

    final context = _Context(_db, zone);
    final datasets = [for (final name in names) _dataset(name, start, end, context)];
    final decimalComma = _decimalComma.contains(_business.language);
    final bytes = await _encode(format, datasets, decimalComma);
    final id = await _files.keep(FilePurpose.export, bytes, contentType: format.contentType, owner: actor);

    _store.write((db) => AuditLog(db, now: _now).append(AuditKinds.accountingExported, actor: actor, device: device, data: {
      "from": _text(from),
      "to": _text(to),
      "datasets": names,
      "format": format.name,
      "rows": rows,
      "fileId": id,
    }));

    return {
      "fileId": id,
      "expires": DateTime.fromMillisecondsSinceEpoch(_now().add(AccountingExport.lifetime).millisecondsSinceEpoch, isUtc: true)
        .toIso8601String(),
    };
  }

  // ---------------------------------------------------------------- windows

  /// Which tickets fall in the window: a closed one by when it closed, a cancelled one by when it
  /// was cancelled (M-64). An open ticket isn't a sale yet.
  static const _salesWindow =
    "((i.status = 'closed' AND substr(i.closed, 1, 23) >= ? AND substr(i.closed, 1, 23) < ?) OR "
    "(i.status = 'cancelled' AND substr(i.cancelled, 1, 23) >= ? AND substr(i.cancelled, 1, 23) < ?))";

  static const _receivablesWindow =
    "i.status = 'closed' AND json_extract(i.payment, '\$.credit') = 1 AND "
    "substr(i.closed, 1, 23) >= ? AND substr(i.closed, 1, 23) < ?";

  int _count(String name, String start, String end) {
    final (sql, params) = switch (name) {
      "sales" => ("SELECT count(*) AS n FROM pos_invoices i WHERE $_salesWindow", [start, end, start, end]),
      "sale_lines" => (
        "SELECT count(*) AS n FROM pos_lines l JOIN pos_invoices i ON i.id = l.invoice_id WHERE $_salesWindow",
        [start, end, start, end],
      ),
      "payments" => (
        "SELECT count(*) AS n FROM money_payments WHERE substr(date, 1, 23) >= ? AND substr(date, 1, 23) < ?",
        [start, end],
      ),
      "receivables" => ("SELECT count(*) AS n FROM pos_invoices i WHERE $_receivablesWindow", [start, end]),
      _ => (
        "SELECT count(*) AS n FROM stock_movements WHERE substr(at, 1, 23) >= ? AND substr(at, 1, 23) < ?",
        [start, end],
      ),
    };

    return _db.select(sql, params).first["n"] as int;
  }

  Dataset _dataset(String name, String start, String end, _Context context) => switch (name) {
    "sales" => Dataset(name, salesColumns, _sales(start, end, context)),
    "sale_lines" => Dataset(name, saleLinesColumns, _saleLines(start, end, context)),
    "payments" => Dataset(name, paymentsColumns, _payments(start, end, context)),
    "receivables" => Dataset(name, receivablesColumns, _receivables(start, end, context)),
    _ => Dataset(name, stockMovementsColumns, _stockMovements(start, end, context)),
  };

  // ---------------------------------------------------------------- datasets

  /// One row per ticket, its figures added up from its lines (POS-20).
  List<List<Object?>> _sales(String start, String end, _Context context) {
    final figures = <String, ({int lines, int units, int subtotal, int tax})>{};
    for (final line in _db.select(
      "SELECT l.invoice_id, l.price, l.qty, l.tax_rate FROM pos_lines l JOIN pos_invoices i ON i.id = l.invoice_id "
      "WHERE $_salesWindow",
      [start, end, start, end],
    )) {
      final id = line["invoice_id"] as String;
      final subtotal = (line["price"] as int) * (line["qty"] as int);
      final now = figures[id] ?? (lines: 0, units: 0, subtotal: 0, tax: 0);

      figures[id] = (
        lines: now.lines + 1,
        units: now.units + (line["qty"] as int),
        subtotal: now.subtotal + subtotal,
        tax: now.tax + Money.percentOf(subtotal, line["tax_rate"] as String),
      );
    }

    return [
      for (final row in _db.select(
        "SELECT i.* FROM pos_invoices i WHERE $_salesWindow ORDER BY coalesce(i.closed, i.cancelled), i.id",
        [start, end, start, end],
      ))
        () {
          final currency = row["currency"] as String;
          final money = context.money(currency);
          final payment = row["payment"] == null ? null : jsonDecode(row["payment"] as String) as Map;
          final sums = figures[row["id"]] ?? (lines: 0, units: 0, subtotal: 0, tax: 0);

          return [
            row["id"],
            row["ticket"],
            row["status"],
            context.local(row["opened"]),
            context.local(row["closed"]),
            context.local(row["cancelled"]),
            context.device(row["device"]),
            context.person(row["seller"]),
            context.person(row["closed_by"]),
            context.person(row["cancelled_by"]),
            payment?["method"],
            payment?["name"],
            payment?["reference"],
            payment == null ? null : payment["credit"] == true,
            sums.lines,
            sums.units,
            money(sums.subtotal),
            money(sums.tax),
            money(sums.subtotal + sums.tax),
            currency,
            row["note"],
          ];
        }(),
    ];
  }

  /// One row per line, in its ticket's order; `line` counts from 1 within the ticket.
  List<List<Object?>> _saleLines(String start, String end, _Context context) {
    final position = <String, int>{};

    return [
      for (final row in _db.select(
        "SELECT l.*, i.ticket, i.status AS sale_status, i.currency FROM pos_lines l "
        "JOIN pos_invoices i ON i.id = l.invoice_id WHERE $_salesWindow "
        "ORDER BY coalesce(i.closed, i.cancelled), i.id, l.position",
        [start, end, start, end],
      ))
        () {
          final money = context.money(row["currency"] as String);
          final qty = row["qty"] as int;
          final subtotal = (row["price"] as int) * qty;
          final tax = Money.percentOf(subtotal, row["tax_rate"] as String);
          final invoice = row["invoice_id"] as String;
          final line = position[invoice] = (position[invoice] ?? 0) + 1;

          return [
            row["id"],
            invoice,
            row["ticket"],
            row["sale_status"],
            line,
            row["product_id"],
            row["sku"],
            row["name"],
            qty,
            money(row["price"] as int),
            row["list"] == null ? null : money(row["list"] as int),
            row["discount"],
            row["tax_rate"],
            money(subtotal),
            money(tax),
            money(subtotal + tax),
            row["currency"],
          ];
        }(),
    ];
  }

  /// Every payment recorded by hand that moved in the window, voided ones with their status (M-64).
  List<List<Object?>> _payments(String start, String end, _Context context) => [
    for (final row in _db.select(
      "SELECT p.*, i.ticket AS ticket_code FROM money_payments p LEFT JOIN pos_invoices i ON i.id = p.ticket_id "
      "WHERE substr(p.date, 1, 23) >= ? AND substr(p.date, 1, 23) < ? ORDER BY p.date, p.id",
      [start, end],
    ))
      () {
        final language = _business.language;
        final counterpart = row["counterpart"] == null ? null : jsonDecode(row["counterpart"] as String) as Map;

        return [
          row["id"],
          context.local(row["date"]),
          context.local(row["created"]),
          row["direction"],
          row["concept"],
          MoneyConcepts.name(row["concept"] as String, language),
          context.money(row["currency"] as String)(row["amount"] as int),
          row["currency"],
          row["method"],
          Settlements.name(row["method"] as String, language),
          _finance.accountLabel(row["account_id"] as String?),
          row["reference"],
          counterpart?["name"],
          counterpart?["contact"],
          row["ticket_code"],
          row["ticket_id"],
          row["note"],
          row["status"],
          context.person(row["registered_by"]),
          context.local(row["voided_at"]),
          context.person(row["voided_by"]),
          row["void_reason"],
        ];
      }(),
  ];

  /// The credit tickets closed in the window, measured now (M-30): what was collected so far, also
  /// after the window.
  List<List<Object?>> _receivables(String start, String end, _Context context) {
    final totals = <String, int>{};
    for (final line in _db.select(
      "SELECT l.invoice_id, l.price, l.qty, l.tax_rate FROM pos_lines l JOIN pos_invoices i ON i.id = l.invoice_id "
      "WHERE $_receivablesWindow",
      [start, end],
    )) {
      final id = line["invoice_id"] as String;
      totals[id] = (totals[id] ?? 0) +
        Pos.lineTotal(line["price"] as int, line["qty"] as int, line["tax_rate"] as String);
    }

    return [
      for (final row in _db.select(
        "SELECT i.* FROM pos_invoices i WHERE $_receivablesWindow ORDER BY i.closed, i.id",
        [start, end],
      ))
        () {
          final id = row["id"] as String;
          final money = context.money(row["currency"] as String);
          final total = totals[id] ?? 0;
          final collected = _finance.collected(id);

          return [
            id,
            row["ticket"],
            context.local(row["closed"]),
            context.person(row["seller"]),
            money(total),
            money(collected),
            money((total - collected).clamp(0, total)),
            row["currency"],
          ];
        }(),
    ];
  }

  /// Every stock movement of the window. `on_hand_change` is what it did to the units on hand: a
  /// reservation or a return waiting to be checked moves none.
  List<List<Object?>> _stockMovements(String start, String end, _Context context) => [
    for (final row in _db.select(
      "SELECT m.*, i.ticket FROM stock_movements m LEFT JOIN pos_invoices i ON i.id = m.invoice_id "
      "WHERE substr(m.at, 1, 23) >= ? AND substr(m.at, 1, 23) < ? ORDER BY m.hlc",
      [start, end],
    ))
      [
        row["id"],
        context.local(row["at"]),
        row["operation"],
        row["reason"],
        row["quantity"],
        switch (row["operation"]) {
          StockOperations.add => row["quantity"],
          StockOperations.remove => -(row["quantity"] as int),
          _ => 0,
        },
        row["product_id"],
        row["sku"],
        row["product_name"],
        row["table_id"],
        row["invoice_id"],
        row["ticket"],
        row["source"],
        context.person(row["actor"]),
        context.device(row["device"]),
        row["note"],
      ],
  ];

  // ---------------------------------------------------------------- arguments

  /// A calendar day `YYYY-MM-DD` that exists.
  static DateTime _date(Object? raw, String field) {
    final match = raw is String ? _day.firstMatch(raw) : null;
    final day = match == null ? null : DateTime.utc(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));
    if (day == null || _text(day) != raw) throw EngineFailure(ErrorCodes.invalidField, {"field": field});

    return day;
  }

  static String _text(DateTime day) =>
    "${day.year.toString().padLeft(4, "0")}-${day.month.toString().padLeft(2, "0")}-${day.day.toString().padLeft(2, "0")}";

  /// Instants to the millisecond, as the tables store them.
  static String _instant(DateTime at) =>
    DateTime.fromMillisecondsSinceEpoch(at.millisecondsSinceEpoch, isUtc: true).toIso8601String().substring(0, 23);
}

/// [ExportFormat.encode] off the isolate that serves every connection: a workbook of many rows
/// takes a while. Top level, so the closure carries only the rows and not the database.
Future<Uint8List> _encode(ExportFormat format, List<Dataset> datasets, bool decimalComma) =>
  Isolate.run(() => format.encode(datasets, decimalComma: decimalComma));

/// What the rows of one export look up more than once: people and devices by name, never by id,
/// and each currency's decimals.
final class _Context {
  _Context(Database db, this.zone)
    : _people = {
        for (final row in db.select("SELECT id, first_name, last_name FROM accounts"))
          row["id"] as String: "${row["first_name"]} ${row["last_name"]}".trim(),
      },
      _devices = {for (final row in db.select("SELECT id, name FROM devices")) row["id"] as String: row["name"] as String};

  final String zone;
  final Map<String, String> _people;
  final Map<String, String> _devices;
  final Map<String, Decimal Function(int)> _money = {};

  String? person(Object? id) => id == null ? null : _people[id] ?? "$id";

  String? device(Object? id) => id == null ? null : _devices[id] ?? "$id";

  /// A stored instant in the company's wall clock (M-63).
  String? local(Object? instant) => instant == null ? null : Zones.local(zone, DateTime.parse(instant as String));

  /// Minor units of [currency] as a [Decimal] with its decimals.
  Decimal Function(int) money(String currency) => _money[currency] ??= () {
    final decimals =
      Catalogs.currencyRows.where((row) => row["code"] == currency).firstOrNull?["decimals"] as int? ?? 2;

    return (int minor) => Decimal(minor, decimals);
  }();
}
