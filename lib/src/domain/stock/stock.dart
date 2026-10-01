import 'dart:convert';

import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../failure.dart';
import '../../ids.dart';
import '../../net/events.dart';
import '../../oplog/oplog.dart';
import '../../storage/store.dart';
import '../../oplog/hlc.dart';
import '../inventory/inventory.dart';

/// The stock ledger (`stock.md`): movements are the truth, `stock_balances` their projection,
/// rewritten in the same transaction as each movement (ST-3). Nothing writes a balance directly.
final class Stock {
  Stock(this._store, this._clock, this._inventory, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Store _store;
  final HlcClock _clock;
  final Inventory _inventory;
  final DateTime Function() _now;

  Database get _db => _store.db;

  /// Who receives `stock/changed`. The POS release adds its tills' audience.
  static const viewPermission = Inventory.viewPermission;

  static const maxQuantity = 1000000;
  static const _maxSummaryPage = 200;
  static const _maxHistoryPage = 100;

  /// `stock.move` (ST-10 to ST-16): one movement, the balance after it. Online in the LAN a
  /// counter never goes negative (ST-13); a POS outbox replay (`source: outbox`) is accepted
  /// anyway and flags the product (ST-14).
  ///
  /// Without [announce] no `stock/changed` is emitted: an import's opening balances (I-44) are
  /// thousands of movements that one `table/changed` already tells about.
  Map<String, Object?> move({
    required String operation,
    required String tableId,
    required String productId,
    required Object? quantity,
    Object? reason,
    Object? note,
    String source = "manual",
    String? invoiceId,
    String? actor,
    String? device,
    String? commandId,
    bool announce = true,
  }) {
    final reasons = StockOperations.reasons[operation];
    if (reasons == null) throw const EngineFailure(ErrorCodes.invalidField, {"field": "operation"});
    if (quantity is! int || quantity < 1 || quantity > maxQuantity) {
      throw const EngineFailure(ErrorCodes.invalidField, {"field": "quantity"});
    }
    if (reason != null && (reason is! String || !reasons.contains(reason))) throw const EngineFailure("invalid_reason");
    if (note != null && (note is! String || note.length > 500)) throw const EngineFailure(ErrorCodes.invalidField, {"field": "note"});

    final why = reason as String? ?? StockOperations.defaults[operation];
    final written = (note as String?)?.trim();

    return _store.write((db) {
      final product = _inventory.product(productId);
      if (product == null || product.table != tableId) throw const EngineFailure(ErrorCodes.notFound);
      if (!product.tracked) throw const EngineFailure("untracked");

      final before = _balance(productId);
      var (onHand, reserved, returns) = (before.onHand, before.reserved, before.returns);

      switch (operation) {
        case StockOperations.add:
          onHand += quantity;
          if (why == "return") returns -= quantity;
        case StockOperations.remove:
          onHand -= quantity;
        case StockOperations.reserve:
          reserved += quantity;
        case StockOperations.unreserve:
          reserved -= quantity;
        case StockOperations.receiveReturn:
          returns += quantity;
      }

      // Only the counters this operation takes from: adding never fails, even onto a
      // negative balance a replay left.
      final negative = switch (operation) {
        StockOperations.remove || StockOperations.reserve => onHand - reserved < 0,
        StockOperations.unreserve => reserved < 0,
        StockOperations.add => returns < 0,
        _ => false,
      };
      final replayed = source == "outbox";

      if (negative && !replayed) {
        throw EngineFailure("insufficient_stock", {
          "onHand": before.onHand,
          "reserved": before.reserved,
          "available": before.onHand - before.reserved,
          "returns": before.returns,
        });
      }

      final review = negative && replayed
        ? 1
        : (operation == StockOperations.add || operation == StockOperations.remove) && why == "correction" ? 0 : before.review;
      final stamp = _clock.tick();
      final id = newId();

      db.execute(
        "INSERT INTO stock_movements (id, product_id, table_id, operation, reason, quantity, note, actor, device, source, "
        "invoice_id, product_name, sku, at, hlc, command_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [id, productId, tableId, operation, why, quantity, written == null || written.isEmpty ? null : written, actor,
          device, source, invoiceId, product.name, product.sku, _now().toUtc().toIso8601String(), stamp.pack(), commandId],
      );
      db.execute(
        "INSERT INTO stock_balances (product_id, table_id, on_hand, reserved, returns, needs_review) VALUES (?, ?, ?, ?, ?, ?) "
        "ON CONFLICT (product_id) DO UPDATE SET table_id = excluded.table_id, on_hand = excluded.on_hand, "
        "reserved = excluded.reserved, returns = excluded.returns, needs_review = excluded.needs_review",
        [productId, tableId, onHand, reserved, returns, review],
      );

      if (source == "manual") _holds(db, productId, tableId, product.sku, operation, quantity);

      Oplog(db).append(hlc: stamp, entity: "stock_movement", entityId: id, kind: "created", payload: {
        "product": productId, "table": tableId, "operation": operation, "reason": why, "quantity": quantity,
        "source": source,
      }, actor: actor, device: device);
      if (announce) {
        EventLog.append(db, Events.stockChanged, {
          "productId": productId,
          "table": tableId,
          "onHand": onHand,
          "reserved": reserved,
          "available": onHand - reserved,
        }, at: _now(), permission: viewPermission);
      }

      return _answer(onHand, reserved, returns, review == 1);
    });
  }

  /// A product's counters: null ones for an untracked product (ST-1), zeros for a tracked one
  /// the ledger never moved (ST-2).
  Map<String, Object?> balanceOf(String productId) {
    final product = _inventory.product(productId);
    if (product == null) throw const EngineFailure(ErrorCodes.notFound);
    if (!product.tracked) return const {"onHand": null, "reserved": null, "available": null, "returns": null, "needsReview": false};

    final balance = _balance(productId);

    return _answer(balance.onHand, balance.reserved, balance.returns, balance.review == 1);
  }

  /// `stock.history {productId, cursor?, size?}`: newest first, by cursor (README paging).
  Map<String, Object?> history(String productId, {String? cursor, int size = 50}) {
    if (size < 1 || size > _maxHistoryPage) throw const EngineFailure(ErrorCodes.invalidField, {"field": "size"});

    final known = _db.select("SELECT 1 FROM inventory_records WHERE id = ?", [productId]);
    if (known.isEmpty) throw const EngineFailure(ErrorCodes.notFound);

    final rows = _db.select(
      "SELECT * FROM stock_movements WHERE product_id = ? AND (? IS NULL OR hlc < ?) ORDER BY hlc DESC LIMIT ?",
      [productId, cursor, cursor, size + 1],
    );
    final page = rows.take(size).toList();

    return {
      "items": [
        for (final row in page)
          {
            "id": row["id"],
            "operation": row["operation"],
            "reason": row["reason"],
            "quantity": row["quantity"],
            "note": row["note"],
            "source": row["source"],
            "invoiceId": row["invoice_id"],
            "productName": row["product_name"],
            "sku": row["sku"],
            "actor": row["actor"],
            "at": row["at"],
          },
      ],
      "cursor": page.isEmpty ? null : page.last["hlc"],
      "more": rows.length > size,
    };
  }

  /// `stock.summary {page, size, match?}` (ST-30 to ST-33): the primary table's products, the
  /// photo first, the fields marked for the summary, then the three numbers.
  Map<String, Object?> summary({required int page, required int size, String match = ""}) {
    if (page < 1) throw const EngineFailure(ErrorCodes.invalidField, {"field": "page"});
    if (size < 1 || size > _maxSummaryPage) throw const EngineFailure(ErrorCodes.invalidField, {"field": "size"});

    final table = _inventory.primaryTable;
    if (table == null) throw const EngineFailure("no_primary_table");

    final tableId = table["id"] as String;
    final fields = _inventory.fieldsOf(tableId);
    final shown = [for (final field in fields) if (field["summary"] == 1 && field["type"] != FieldTypes.stock) field];
    final image = fields.where((field) => field["type"] == FieldTypes.image).firstOrNull;
    final title = fields.where((field) => field["type"] == FieldTypes.title).firstOrNull;
    final tracked = fields.any((field) => field["type"] == FieldTypes.stock);
    final (where, arguments) = _inventory.matchOf(tableId, fields, match);
    final order = title == null ? "" : "json_extract(r.data, '\$.\"${title["id"]}\"') COLLATE NOCASE, ";

    final total = _db.select("SELECT count(*) AS n FROM inventory_records r WHERE $where", arguments).first["n"] as int;
    final rows = _db.select(
      "SELECT r.id, r.data, b.on_hand, b.reserved, b.needs_review FROM inventory_records r "
      "LEFT JOIN stock_balances b ON b.product_id = r.id WHERE $where "
      "ORDER BY coalesce(b.needs_review, 0) DESC, $order r.id LIMIT ? OFFSET ?",
      [...arguments, size, (page - 1) * size],
    );

    return {
      "table": tableId,
      "total": total,
      "page": page,
      "size": size,
      "columns": [
        {"key": "image", "name": null, "type": FieldTypes.image, "fixed": true},
        for (final field in shown)
          {
            "key": field["id"],
            "name": field["name"],
            "type": field["type"],
            "width": field["width"],
            "options": jsonDecode(field["options"] as String),
            "unit": field["unit"],
            "fixed": false,
          },
        {"key": "stock", "name": null, "type": FieldTypes.stock, "fixed": true},
        {"key": "reserved", "name": null, "type": FieldTypes.number, "fixed": true},
        {"key": "performance", "name": null, "type": FieldTypes.number, "fixed": true},
      ],
      "data": {
        "keys": ["id", "image", for (final field in shown) field["id"], "stock", "reserved", "performance", "needsReview"],
        "values": [
          for (final row in rows)
            _summaryRow(row, shown, image, tracked),
        ],
      },
    };
  }

  List<Object?> _summaryRow(Row row, List<Row> shown, Row? image, bool tracked) {
    final data = jsonDecode(row["data"] as String) as Map<String, Object?>;
    final images = image == null ? null : data[image["id"]];
    final cover = images is List && images.isNotEmpty ? "${images.first}" : null;
    final onHand = row["on_hand"] as int? ?? 0;
    final reserved = row["reserved"] as int? ?? 0;

    return [
      row["id"],
      cover == null ? null : cover.contains("://") ? {"id": null, "url": cover} : {"id": cover},
      for (final field in shown) data[field["id"]],
      tracked ? onHand - reserved : null,
      tracked ? reserved : null,
      null,
      row["needs_review"] == 1,
    ];
  }

  /// Manual holds follow the stock screen's reserves; a release takes from manual holds first,
  /// then from POS holds, oldest first (ST-22).
  void _holds(Database db, String productId, String tableId, String? sku, String operation, int quantity) {
    final stamp = _now().toUtc().toIso8601String();

    if (operation == StockOperations.reserve) {
      db.execute(
        "INSERT INTO stock_holds (id, product_id, table_id, sku, qty, status, owner_kind, created) VALUES (?, ?, ?, ?, ?, 'active', 'manual', ?)",
        [newId(), productId, tableId, sku, quantity, stamp],
      );
      return;
    }
    if (operation != StockOperations.unreserve) return;

    var left = quantity;
    for (final hold in db.select(
      "SELECT id, qty FROM stock_holds WHERE product_id = ? AND status = 'active' "
      "ORDER BY CASE owner_kind WHEN 'manual' THEN 0 ELSE 1 END, created",
      [productId],
    )) {
      if (left == 0) break;

      final qty = hold["qty"] as int;
      final taken = qty < left ? qty : left;
      left -= taken;
      db.execute(
        "UPDATE stock_holds SET qty = ?, status = CASE WHEN ? = 0 THEN 'released' ELSE status END WHERE id = ?",
        [qty - taken, qty - taken, hold["id"]],
      );
    }
  }

  ({int onHand, int reserved, int returns, int review}) _balance(String productId) {
    final row = _db.select("SELECT * FROM stock_balances WHERE product_id = ?", [productId]).firstOrNull;

    return (
      onHand: row?["on_hand"] as int? ?? 0,
      reserved: row?["reserved"] as int? ?? 0,
      returns: row?["returns"] as int? ?? 0,
      review: row?["needs_review"] as int? ?? 0,
    );
  }

  static Map<String, Object?> _answer(int onHand, int reserved, int returns, bool review) => {
    "onHand": onHand,
    "reserved": reserved,
    "available": onHand - reserved,
    "returns": returns,
    "needsReview": review,
  };

  /// Recomputes every balance from the movements (ST-3's maintenance action). Answers the
  /// products whose stored balance was different.
  List<String> rebuild() => _store.write((db) {
    final differ = <String>[];
    final computed = <String, (String, int, int, int)>{};

    for (final row in db.select("SELECT * FROM stock_movements ORDER BY hlc")) {
      final product = row["product_id"] as String;
      var (table, onHand, reserved, returns) = computed[product] ?? (row["table_id"] as String, 0, 0, 0);
      final quantity = row["quantity"] as int;

      switch (row["operation"]) {
        case StockOperations.add:
          onHand += quantity;
          if (row["reason"] == "return") returns -= quantity;
        case StockOperations.remove:
          onHand -= quantity;
        case StockOperations.reserve:
          reserved += quantity;
        case StockOperations.unreserve:
          reserved -= quantity;
        case StockOperations.receiveReturn:
          returns += quantity;
      }
      computed[product] = (table, onHand, reserved, returns);
    }

    for (final MapEntry(key: product, value: (table, onHand, reserved, returns)) in computed.entries) {
      final stored = _balance(product);
      if (stored.onHand != onHand || stored.reserved != reserved || stored.returns != returns) differ.add(product);

      db.execute(
        "INSERT INTO stock_balances (product_id, table_id, on_hand, reserved, returns) VALUES (?, ?, ?, ?, ?) "
        "ON CONFLICT (product_id) DO UPDATE SET on_hand = excluded.on_hand, reserved = excluded.reserved, returns = excluded.returns",
        [product, table, onHand, reserved, returns],
      );
    }

    return differ;
  });
}
