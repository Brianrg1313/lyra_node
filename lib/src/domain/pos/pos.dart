import 'dart:convert';

import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../failure.dart';
import '../../ids.dart';
import '../../net/events.dart';
import '../../oplog/oplog.dart';
import '../../oplog/hlc.dart';
import '../../storage/store.dart';
import '../business/business.dart';
import '../business/zones.dart';
import '../inventory/inventory.dart';
import '../sales/sales.dart';
import '../stock/stock.dart';
import 'money.dart';

/// The counter (`pos.md`): the catalogue read by field type, and the ticket, a document from its
/// first line whose lines hold stock.
///
/// Every figure is computed here from frozen prices and rates (POS-20, POS-22): no op takes a
/// total. Money is in minor units of the company's currency; the app's source turns it into the
/// numbers its models hold.
final class Pos {
  Pos(this._store, this._clock, this._inventory, this._stock, this._business, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final Store _store;
  final HlcClock _clock;
  final Inventory _inventory;
  final Stock _stock;
  final Business _business;
  final DateTime Function() _now;

  Database get _db => _store.db;

  /// Who receives `invoice/*` (`pos.md`, events).
  static const audience = ["pos", "sales"];

  static const _open = "open";
  static const _closed = "closed";
  static const _cancelled = "cancelled";

  // ---------------------------------------------------------------- pos.catalog

  /// `pos.summary` (POS-5): the tickets [account] closed today, in the company's zone, and the
  /// primary table's categories.
  Map<String, Object?> summary(String account) {
    final (start, end) = Zones.dayOf(_business.timezone, _now());
    final sales = _db.select(
      "SELECT count(*) AS n FROM pos_invoices WHERE status = 'closed' AND closed_by = ? AND closed >= ? AND closed < ?",
      [account, _instant(start), _instant(end)],
    ).first["n"] as int;

    final table = _inventory.primaryTable;
    final categories = <String>{
      if (table != null)
        for (final field in _inventory.fieldsOf(table["id"] as String))
          if (field["type"] == FieldTypes.categories)
            for (final option in jsonDecode(field["options"] as String) as List) "$option",
    };

    return {"mine": {"sales": sales}, "categories": categories.toList()};
  }

  /// `pos.methods`: the settlement kinds in the company's language, without credit (POS-33).
  Map<String, Object?> methods() => {
    "methods": Settlements.rows(_business.language, credit: false),
    "channels": const ["pos"],
  };

  /// `pos.catalog {size, cursor?, search?, category?}` (POS-1 to POS-4): the primary table's
  /// products by name without case or accents, then id, by cursor.
  Map<String, Object?> catalog({required int size, String? cursor, String search = "", String category = ""}) {
    if (size < 1 || size > PosLimits.maxPage) throw const EngineFailure(ErrorCodes.invalidField, {"field": "size"});

    final table = _inventory.primaryTable;
    if (table == null) throw const EngineFailure("no_primary_table");

    final tableId = table["id"] as String;
    final columns = _Columns(_inventory.fieldsOf(tableId));
    final key = columns.title == null ? "''" : "coalesce(fold(${_cell(columns.title!)}), '')";
    final where = <String>["r.table_id = ?", "r.deleted = 0"];
    final arguments = <Object?>[tableId];

    final text = fold(search.trim());
    if (text.isNotEmpty) {
      final searched = [?columns.title, ?columns.sku, ?columns.barcode];
      if (searched.isEmpty) {
        where.add("0");
      } else {
        final pattern = "%${text.replaceAll(r"\", r"\\").replaceAll("%", r"\%").replaceAll("_", r"\_")}%";
        where.add("(${[for (final field in searched) "fold(${_cell(field)}) LIKE ? ESCAPE '\\'"].join(" OR ")})");
        arguments.addAll(List.filled(searched.length, pattern));
      }
    }

    if (category.isNotEmpty) {
      if (columns.categories.isEmpty) {
        where.add("0");
      } else {
        where.add("(${[
          for (final field in columns.categories)
            "EXISTS (SELECT 1 FROM json_each(r.data, '\$.\"$field\"') c WHERE c.value = ?)",
        ].join(" OR ")})");
        arguments.addAll(List.filled(columns.categories.length, category));
      }
    }

    if (cursor != null && cursor.isNotEmpty) {
      final (after, id) = _readCursor(cursor);
      where.add("($key > ? OR ($key = ? AND r.id > ?))");
      arguments.addAll([after, after, id]);
    }

    final rows = _db.select(
      "SELECT r.id, r.data, $key AS sort, b.on_hand, b.reserved, $_sitePrice FROM inventory_records r "
      "LEFT JOIN stock_balances b ON b.product_id = r.id $_sitePriceJoin WHERE ${where.join(" AND ")} ORDER BY sort, r.id LIMIT ?",
      [...arguments, size + 1],
    );
    final page = rows.take(size).toList();
    final more = rows.length > size;
    final decimals = _business.decimals;

    return {
      "table": tableId,
      "size": size,
      "cursor": more ? _writeCursor(page.last["sort"] as String, page.last["id"] as String) : null,
      "more": more,
      "currency": _business.currency,
      "data": {
        "keys": const ["id", "name", "sku", "barcode", "price", "stock", "reserved", "image", "categories"],
        "values": [
          for (final row in page) _catalogRow(row, columns, decimals),
        ],
      },
    };
  }

  List<Object?> _catalogRow(Row row, _Columns columns, int decimals) {
    final data = jsonDecode(row["data"] as String) as Map<String, Object?>;
    final product = columns.read(row["id"] as String, data, decimals, site: _siteOf(row));
    final onHand = row["on_hand"] as int? ?? 0;
    final reserved = row["reserved"] as int? ?? 0;
    final images = columns.image == null ? null : data[columns.image];
    final cover = images is List && images.isNotEmpty ? "${images.first}" : null;

    return [
      row["id"],
      product.name,
      product.sku,
      product.barcode,
      product.price,
      columns.tracked ? onHand - reserved : null,
      columns.tracked ? reserved : null,
      cover == null ? null : cover.contains("://") ? {"id": null, "url": cover} : {"id": cover},
      [
        for (final field in columns.categories)
          if (data[field] case final List labels) ...labels.map((label) => "$label"),
      ],
    ];
  }

  /// The site's own price of `r`, beside its record (POS-7b).
  static const _sitePrice = "sp.price AS site_price, sp.discount AS site_discount, sp.inherits_discount AS site_inherits";
  static const _sitePriceJoin = "LEFT JOIN site_prices sp ON sp.product_id = r.id AND sp.deleted = 0";

  static _SitePrice? _siteOf(Row row) => row["site_inherits"] == null
    ? null
    : (price: row["site_price"] as String?, discount: row["site_discount"] as String?, inheritsDiscount: row["site_inherits"] == 1);

  static String _cell(String fieldId) => "json_extract(r.data, '\$.\"$fieldId\"')";

  static String _writeCursor(String key, String id) => base64Url.encode(utf8.encode(jsonEncode([key, id])));

  static (String, String) _readCursor(String cursor) {
    try {
      final parts = jsonDecode(utf8.decode(base64Url.decode(cursor))) as List;

      return (parts[0] as String, parts[1] as String);
    } catch (_) {
      throw const EngineFailure(ErrorCodes.invalidField, {"field": "cursor"});
    }
  }

  // ---------------------------------------------------------------- pos.invoice

  /// `pos.invoices.open {tax?}` (POS-10, POS-40): an invoice with no lines and its code, minted
  /// now from [deviceCode]'s series.
  Map<String, Object?> open({required Object? tax, required String seller, required String device, required String deviceCode}) {
    final rate = tax == null ? "0" : Money.percent(tax);
    if (rate == null) throw const EngineFailure(ErrorCodes.invalidField, {"field": "tax"});

    return _store.write((db) {
      final number = db.select("SELECT next FROM pos_series WHERE device_id = ?", [device]).firstOrNull?["next"] as int? ?? 1;
      db.execute(
        "INSERT INTO pos_series (device_id, next) VALUES (?, ?) ON CONFLICT (device_id) DO UPDATE SET next = excluded.next",
        [device, number + 1],
      );

      final id = newId();
      final ticket = "$deviceCode-${"$number".padLeft(6, "0")}";
      final stamp = _clock.tick();

      db.execute(
        "INSERT INTO pos_invoices (id, ticket, status, device, seller, default_tax, currency, opened, created_hlc, updated_hlc) "
        "VALUES (?, ?, 'open', ?, ?, ?, ?, ?, ?, ?)",
        [id, ticket, device, seller, rate, _business.currency, _instant(_now()), stamp.pack(), stamp.pack()],
      );
      Oplog(db).append(hlc: stamp, entity: "pos_invoice", entityId: id, kind: "created",
        payload: {"ticket": ticket, "tax": rate}, actor: seller, device: device);

      final row = _row(id);
      final invoice = _invoice(row);
      _announce(db, Events.invoiceOpened, invoice);
      _progress(db, row);

      return invoice;
    });
  }

  /// `pos.invoices.line {id, productId | lineId | concept + price, add | quantity, tax?}`
  /// (POS-11 to POS-18). A typed-in charge and a changed rate are `pos.sell`, like any line: the
  /// cloud has no key of their own (`session.md` P-4).
  Map<String, Object?> line(String id, Map<String, Object?> args, {
    String? actor,
    String? device,
  }) => _store.write((db) {
    final invoice = _writable(id);
    final total = _invoice(invoice)["total"];
    final productId = args["productId"];
    final lineId = args["lineId"];
    final concept = args["concept"];
    final addresses = [productId, lineId, concept].where((value) => value != null).length;

    if (addresses != 1) throw const EngineFailure(ErrorCodes.badRequest);
    if (args.containsKey("add") == args.containsKey("quantity")) throw const EngineFailure(ErrorCodes.badRequest);

    final add = args["add"];
    final quantity = args["quantity"];
    if (add != null && add is! int || add == 0) throw const EngineFailure(ErrorCodes.invalidField, {"field": "add"});
    if (quantity != null && (quantity is! int || quantity < 0)) {
      throw const EngineFailure(ErrorCodes.invalidField, {"field": "quantity"});
    }

    final rate = args["tax"] == null ? null : Money.percent(args["tax"]);
    if (args["tax"] != null && rate == null) throw const EngineFailure(ErrorCodes.invalidField, {"field": "tax"});

    final stamp = _clock.tick();
    final lines = _lines(id);
    Row? current;

    if (lineId != null) {
      current = lines.where((line) => line["id"] == lineId).firstOrNull;
      if (current == null) throw const EngineFailure(ErrorCodes.notFound, {"field": "lineId"});
    } else if (productId != null) {
      if (productId is! String) throw const EngineFailure(ErrorCodes.invalidField, {"field": "productId"});
      current = lines.where((line) => line["product_id"] == productId).firstOrNull;
    }

    final before = current?["qty"] as int? ?? 0;
    final after = quantity as int? ?? before + (add as int);
    if (after > PosLimits.maxUnits) throw const EngineFailure("too_many_units", {"max": PosLimits.maxUnits});


    if (current == null) {
      if (after <= 0) throw EngineFailure(ErrorCodes.invalidField, {"field": add == null ? "quantity" : "add"});

      final position = lines.isEmpty ? 1 : (lines.last["position"] as int) + 1;
      final line = newId();

      if (concept != null) {
        if (concept is! String || concept.trim().isEmpty || concept.trim().length > PosLimits.maxConcept) {
          throw const EngineFailure(ErrorCodes.invalidField, {"field": "concept"});
        }
        final price = Money.sent(args["price"]);
        if (price == null) throw const EngineFailure(ErrorCodes.invalidField, {"field": "price"});

        db.execute(
          "INSERT INTO pos_lines (id, invoice_id, position, name, qty, price, tax_rate) VALUES (?, ?, ?, ?, ?, ?, ?)",
          [line, id, position, concept.trim(), after, price, rate ?? invoice["default_tax"]],
        );
      } else {
        final product = _product(productId as String);
        if (product.price == null) throw EngineFailure("no_price", {"product": product.name});

        db.execute(
          "INSERT INTO pos_lines (id, invoice_id, position, product_id, table_id, tracked, name, sku, qty, price, list, "
          "discount, tax_rate) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          [line, id, position, productId, product.table, product.tracked ? 1 : 0, product.name ?? product.sku ?? "",
            product.sku, after, product.price, product.list, product.discount, rate ?? invoice["default_tax"]],
        );
        if (product.tracked) _hold(line, id, product.table, productId, after, product.name, actor: actor, device: device);
      }
    } else if (after <= 0) {
      _release(current, id, actor: actor, device: device);
      db.execute("DELETE FROM pos_lines WHERE id = ?", [current["id"]]);
    } else {
      final line = current["id"] as String;
      if (current["tracked"] == 1) {
        if (after > before) {
          _hold(line, id, current["table_id"] as String, current["product_id"] as String, after - before,
            current["name"] as String, actor: actor, device: device);
        } else {
          final held = _stock.held(line);
          if (held > after) _unhold(current, id, held - after, actor: actor, device: device);
        }
      }
      db.execute("UPDATE pos_lines SET qty = ?, tax_rate = ? WHERE id = ?", [after, rate ?? current["tax_rate"], line]);
    }

    db.execute("UPDATE pos_invoices SET updated_hlc = ? WHERE id = ?", [stamp.pack(), id]);
    Oplog(db).append(hlc: stamp, entity: "pos_invoice", entityId: id, kind: "line",
      payload: {"productId": ?productId, "lineId": ?lineId, "concept": ?concept, "qty": after < 0 ? 0 : after, "tax": ?rate},
      actor: actor, device: device);

    final row = _row(id);
    final answer = _invoice(row);
    _announce(db, Events.invoiceUpdated, answer);
    // The board only cares when the sale is worth something else (`sales.md`, events).
    if (answer["total"] != total) _progress(db, row);

    return {"invoice": answer};
  });

  /// `pos.invoices.close {id, method, reference?, note?}` (POS-30 to POS-34): every hold topped up
  /// to its line, then consumed by a `remove` / `sale`; the invoice closed, in one transaction.
  Map<String, Object?> close(String id, {
    required Object? method,
    Object? reference,
    Object? note,
    required String actor,
    String? device,
  }) => _store.write((db) {
    _writable(id);

    final kind = method is String ? Settlements.kinds[method] : null;
    if (kind == null || kind.$3) throw const EngineFailure("unknown_method");
    final paid = _text(reference, "reference", PosLimits.maxReference);
    final written = _text(note, "note", PosLimits.maxNote);

    final lines = _lines(id);
    if (lines.isEmpty) throw const EngineFailure("empty_invoice");

    for (final line in lines.where((line) => line["tracked"] == 1)) {
      final missing = (line["qty"] as int) - _stock.held(line["id"] as String);
      if (missing > 0) {
        _hold(line["id"] as String, id, line["table_id"] as String, line["product_id"] as String, missing,
          line["name"] as String, actor: actor, device: device);
      }
    }
    for (final line in lines.where((line) => line["tracked"] == 1)) {
      _stock.move(
        operation: StockOperations.remove,
        tableId: line["table_id"] as String,
        productId: line["product_id"] as String,
        quantity: line["qty"],
        reason: "sale",
        source: "pos",
        invoiceId: id,
        hold: line["id"] as String,
        actor: actor,
        device: device,
      );
    }

    final stamp = _clock.tick();
    final at = _instant(_now());
    final payment = {
      "method": method,
      "name": Settlements.name(method as String, _business.language),
      "reference": paid,
      "credit": false,
    };

    db.execute(
      "UPDATE pos_invoices SET status = 'closed', closed_by = ?, payment = ?, note = ?, closed = ?, handover = ?, "
      "updated_hlc = ? WHERE id = ?",
      [actor, jsonEncode(payment), written, at, jsonEncode({"mode": "immediate", "state": "done", "at": at, "by": actor}),
        stamp.pack(), id],
    );
    Oplog(db).append(hlc: stamp, entity: "pos_invoice", entityId: id, kind: "closed",
      payload: {"method": method}, actor: actor, device: device);

    final row = _row(id);
    final invoice = _invoice(row);
    _announce(db, Events.invoiceClosed, invoice);
    _progress(db, row);

    return invoice;
  });

  /// `pos.invoices.cancel {id}` (POS-35): every hold released, the invoice kept as `cancelled`.
  void cancel(String id, {required String actor, String? device}) => _store.write((db) {
    _writable(id);

    for (final line in _lines(id)) {
      _release(line, id, actor: actor, device: device);
    }

    final stamp = _clock.tick();
    db.execute(
      "UPDATE pos_invoices SET status = 'cancelled', cancelled_by = ?, cancelled = ?, updated_hlc = ? WHERE id = ?",
      [actor, _instant(_now()), stamp.pack(), id],
    );
    Oplog(db).append(hlc: stamp, entity: "pos_invoice", entityId: id, kind: "cancelled", payload: const {},
      actor: actor, device: device);
    final row = _row(id);
    _announce(db, Events.invoiceCancelled, _invoice(row));
    _progress(db, row);
  });

  /// `pos.invoices.list {mine?, size?}` (POS-45): open invoices, oldest first; [device] limits
  /// them to one till.
  Map<String, Object?> list({String? device, int size = 20}) {
    if (size < 1 || size > PosLimits.maxPage) throw const EngineFailure(ErrorCodes.invalidField, {"field": "size"});

    final rows = _db.select(
      "SELECT * FROM pos_invoices WHERE status = 'open' AND (? IS NULL OR device = ?) ORDER BY opened, id LIMIT ?",
      [device, device, size],
    );

    return {"invoices": [for (final row in rows) _invoice(row)]};
  }

  /// [row] as the sales board reads it: every figure computed from its lines.
  Map<String, Object?> document(Row row) => _invoice(row);

  /// What a line comes to (POS-20): `price × qty` plus its tax, rounded once. A ticket's total is
  /// the sum of its lines', which is how the money screen adds tickets up without reading each one.
  static int lineTotal(int price, int qty, String rate) {
    final subtotal = price * qty;

    return subtotal + Money.percentOf(subtotal, rate);
  }

  // ---------------------------------------------------------------- internals

  /// [id] as an invoice a write may change (POS-18).
  Row _writable(String id) {
    final row = _row(id);

    return switch (row["status"]) {
      _closed => throw const EngineFailure("invoice_closed"),
      _cancelled => throw const EngineFailure("invoice_cancelled"),
      _ => row,
    };
  }

  Row _row(String id) {
    final row = _db.select("SELECT * FROM pos_invoices WHERE id = ?", [id]).firstOrNull;
    if (row == null) throw const EngineFailure(ErrorCodes.notFound);

    return row;
  }

  List<Row> _lines(String invoiceId) =>
    _db.select("SELECT * FROM pos_lines WHERE invoice_id = ? ORDER BY position", [invoiceId]).toList();

  /// A product of the primary table, with what a new line freezes (POS-12).
  ({String table, String? name, String? sku, int? price, int? list, String? discount, bool tracked}) _product(String id) {
    final table = _inventory.primaryTable;
    final row = table == null
      ? null
      : _db.select(
          "SELECT r.data, $_sitePrice FROM inventory_records r $_sitePriceJoin WHERE r.id = ? AND r.table_id = ? AND r.deleted = 0",
          [id, table["id"]],
        ).firstOrNull;
    if (row == null) throw const EngineFailure(ErrorCodes.notFound, {"field": "productId"});

    final tableId = table!["id"] as String;
    final columns = _Columns(_inventory.fieldsOf(tableId));
    final product = columns.read(id, jsonDecode(row["data"] as String) as Map<String, Object?>, _business.decimals,
      site: _siteOf(row));

    return (
      table: tableId,
      name: product.name,
      sku: product.sku,
      price: product.price,
      list: product.list,
      discount: product.discount,
      tracked: columns.tracked,
    );
  }

  /// Takes [units] more for [line]'s hold (POS-13): refused with the product and what is left.
  void _hold(String line, String invoiceId, String tableId, String productId, int units, String? name, {
    String? actor,
    String? device,
  }) {
    try {
      _stock.move(operation: StockOperations.reserve, tableId: tableId, productId: productId, quantity: units,
        source: "pos", invoiceId: invoiceId, hold: line, actor: actor, device: device);
    } on EngineFailure catch (failure) {
      if (failure.code != "insufficient_stock") rethrow;

      throw EngineFailure("insufficient_stock", {
        "product": name,
        "productId": productId,
        "available": failure.data["available"],
      });
    }
  }

  /// Gives back [units] of [line]'s hold (`unreserve` / `cancelled`).
  void _unhold(Row line, String invoiceId, int units, {String? actor, String? device}) => _stock.move(
    operation: StockOperations.unreserve,
    tableId: line["table_id"] as String,
    productId: line["product_id"] as String,
    quantity: units,
    reason: "cancelled",
    source: "pos",
    invoiceId: invoiceId,
    hold: line["id"] as String,
    actor: actor,
    device: device,
  );

  /// Gives back everything [line] still holds.
  void _release(Row line, String invoiceId, {String? actor, String? device}) {
    if (line["tracked"] != 1) return;

    final held = _stock.held(line["id"] as String);
    if (held > 0) _unhold(line, invoiceId, held, actor: actor, device: device);
  }

  /// The invoice as the app's `PosInvoice` reads it, every figure computed from its lines
  /// (POS-20): per line `subtotal = price × qty`, `tax` rounded once, `total` their sum.
  Map<String, Object?> _invoice(Row row) {
    final open = row["status"] == _open;
    final taxes = <String, (int, int)>{};
    var (units, held, subtotal, tax) = (0, 0, 0, 0);

    final items = [
      for (final line in _lines(row["id"] as String))
        () {
          final qty = line["qty"] as int;
          final rate = line["tax_rate"] as String;
          final lineSubtotal = (line["price"] as int) * qty;
          final lineTax = Money.percentOf(lineSubtotal, rate);
          final lineHeld = open && line["tracked"] == 1 ? _stock.held(line["id"] as String) : 0;
          final (base, amount) = taxes[rate] ?? (0, 0);

          taxes[rate] = (base + lineSubtotal, amount + lineTax);
          units += qty;
          held += lineHeld;
          subtotal += lineSubtotal;
          tax += lineTax;

          return {
            "lineId": line["id"],
            "productId": line["product_id"],
            "name": line["name"],
            "sku": line["sku"],
            "qty": qty,
            "held": lineHeld,
            // An untracked product's line holds nothing (POS-6): its `held` of 0 isn't a release.
            "tracked": line["tracked"] == 1,
            "price": line["price"],
            "list": line["list"],
            "discount": line["discount"],
            "taxRate": rate,
            "subtotal": lineSubtotal,
            "tax": lineTax,
            "total": lineSubtotal + lineTax,
          };
        }(),
    ];

    return {
      "id": row["id"],
      "ticket": row["ticket"],
      "status": row["status"],
      "open": open,
      "device": row["device"],
      "seller": row["seller"],
      "closedBy": row["closed_by"],
      "cancelledBy": row["cancelled_by"],
      "defaultTax": row["default_tax"],
      "items": items,
      "units": units,
      "held": held,
      "subtotal": subtotal,
      "tax": tax,
      "total": subtotal + tax,
      "taxes": [
        for (final MapEntry(key: rate, value: (base, amount)) in taxes.entries)
          {"rate": rate, "base": base, "amount": amount},
      ],
      "payment": row["payment"] == null ? null : jsonDecode(row["payment"] as String),
      "note": row["note"],
      "currency": row["currency"],
      "opened": row["opened"],
      "closed": row["closed"],
      "origin": row["origin"],
    };
  }

  void _announce(Database db, String event, Map<String, Object?> invoice) => EventLog.append(db, event, {
    "id": invoice["id"],
    "ticket": invoice["ticket"],
    "units": invoice["units"],
    "total": invoice["total"],
  }, at: _now(), anyOf: audience);

  void _progress(Database db, Row invoice) =>
    Sales.announce(db, invoice, language: _business.language, at: _now());

  /// An optional text argument, trimmed; null when blank.
  static String? _text(Object? raw, String field, int max) {
    if (raw == null) return null;
    if (raw is! String) throw EngineFailure(ErrorCodes.invalidField, {"field": field});

    final text = raw.replaceAll(RegExp(r"\p{Cc}", unicode: true), " ").trim();
    if (text.length > max) throw EngineFailure(ErrorCodes.invalidField, {"field": field});

    return text.isEmpty ? null : text;
  }

  /// Instants to the millisecond, so stored ones compare as text (`closed >= start`).
  static String _instant(DateTime at) =>
    DateTime.fromMillisecondsSinceEpoch(at.millisecondsSinceEpoch, isUtc: true).toIso8601String();
}

/// A product's own price at this site (POS-7b): `price` null is the `PRICE` cell's; unless
/// `inheritsDiscount`, `discount` replaces the `DISCOUNT` cell (null: not on offer here).
typedef _SitePrice = ({String? price, String? discount, bool inheritsDiscount});

/// The primary table's fields by type, as the counter reads a product (POS-1).
final class _Columns {
  _Columns(List<Row> fields) {
    String? first(String type) => fields.where((field) => field["type"] == type).firstOrNull?["id"] as String?;

    title = first(FieldTypes.title);
    sku = first(FieldTypes.sku);
    barcode = first(FieldTypes.barcode);
    price = first(FieldTypes.price);
    discount = first(FieldTypes.discount);
    image = first(FieldTypes.image);
    categories = [for (final field in fields) if (field["type"] == FieldTypes.categories) field["id"] as String];
    tracked = fields.any((field) => field["type"] == FieldTypes.stock);
  }

  late final String? title, sku, barcode, price, discount, image;
  late final List<String> categories;
  late final bool tracked;

  /// [data]'s product: `price` is the list price net of its own discount (POS-7), null without a
  /// price (POS-2). [site]'s figures stand for the cells they replace (POS-7b).
  ({String? name, String? sku, String? barcode, int? price, int? list, String? discount}) read(
    String id, Map<String, Object?> data, int decimals, {_SitePrice? site}
  ) {
    String? text(String? field) => field == null || data[field] == null ? null : "${data[field]}";

    final list = site?.price != null
      ? Money.minor(site!.price, decimals)
      : price == null ? null : Money.minor(data[price], decimals);
    final percent = site != null && !site.inheritsDiscount
      ? Money.percent(site.discount)
      : discount == null ? null : Money.percent(data[discount]);
    final off = percent != null && percent != "0" ? percent : null;

    return (
      name: text(title),
      sku: text(sku),
      barcode: text(barcode),
      price: list == null ? null : off == null ? list : Money.discounted(list, off),
      list: list,
      discount: list == null ? null : off,
    );
  }
}
