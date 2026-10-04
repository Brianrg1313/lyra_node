import 'dart:convert';

import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../failure.dart';
import '../../net/events.dart';
import '../../oplog/hlc.dart';
import '../../oplog/oplog.dart';
import '../../storage/store.dart';
import '../business/business.dart';
import '../pos/pos.dart';

/// The sales board (`sales.md`): nothing stores a list of sales. Each row is a POS invoice
/// **measured when it is read** (open → `open`; charged → its handover, then `completed`), and the
/// one write is the handover, the fact nobody else can measure.
///
/// Money is in minor units of the sale's currency, as on the ticket (`pos.md`).
final class Sales {
  Sales(this._store, this._clock, this._pos, this._business, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final Store _store;
  final HlcClock _clock;
  final Pos _pos;
  final Business _business;
  final DateTime Function() _now;

  Database get _db => _store.db;

  /// Who may read any sale, not only the ones they sold (SA-11): the cloud lists every sale to
  /// whoever holds `sales`.
  static const viewAll = "sales";

  /// `sales.catalog`: the stages a master measures, the handover modes and the channels (SA-2).
  Map<String, Object?> catalog() {
    final language = _business.language;

    return {
      "stages": SaleStages.rows(language, offline: true),
      "handover": Handover.rows(language),
      "channels": SaleChannels.rows(language),
    };
  }

  // ---------------------------------------------------------------- sales.list

  /// `sales.list {section, stage?, channel?, mine?, page, size}` (SA-10 to SA-12). [seller] limits
  /// the rows to one person's. A stage names its own section, which the answer echoes.
  Map<String, Object?> list({
    required String section,
    String? stage,
    String? channel,
    String? seller,
    int page = 1,
    int size = 30,
  }) {
    final stages = [
      for (final MapEntry(key: code, value: kind) in SaleStages.kinds.entries)
        if (kind.$4 && kind.$1 == section && (stage == null || stage == code)) code,
    ];
    final attention = [for (final MapEntry(key: code, value: kind) in SaleStages.kinds.entries) if (kind.$3) code];
    final empty = {"section": section, "page": page, "size": size, "total": 0, "sales": const <Object?>[]};

    if (stages.isEmpty || (channel != null && channel != SaleChannels.pos)) return empty;

    String marks(List<String> codes) => List.filled(codes.length, "?").join(", ");
    final measured = """
      WITH measured AS (
        SELECT i.*, $_stageSql AS stage, $_sinceSql AS since FROM pos_invoices i
        WHERE i.status IN ('open', 'closed') AND (? IS NULL OR i.seller = ?)
      )
    """;
    final filter = "WHERE stage IN (${marks(stages)})";

    final total = _db.select("$measured SELECT count(*) AS n FROM measured $filter", [seller, seller, ...stages])
      .first["n"] as int;
    final rows = _db.select(
      "$measured SELECT * FROM measured $filter "
      "ORDER BY stage IN (${marks(attention)}) DESC, since, id LIMIT ? OFFSET ?",
      [seller, seller, ...stages, ...attention, size, (page - 1) * size],
    );

    return {...empty, "total": total, "sales": [for (final invoice in rows) row(invoice)]};
  }

  /// One invoice as a row of the board, the app's `SaleModel`. [section] is only on a write's
  /// answer (SA-24): a page belongs to the section that was asked for.
  Map<String, Object?> row(Row invoice, {bool section = false}) {
    final document = _pos.document(invoice);
    final measured = measure(invoice);
    final handover = invoice["status"] == "closed" ? _handover(invoice) : null;

    return {
      "id": invoice["id"],
      "source": invoice["status"] == "open" ? "invoice" : "ticket",
      "ticket": invoice["ticket"],
      ..._standing(measured, _business.language),
      "channel": SaleChannels.pos,
      "customer": null,
      "contact": null,
      "units": document["units"],
      "total": document["total"],
      "currency": invoice["currency"],
      "method": (document["payment"] as Map?)?["method"],
      "collected": null,
      "outstanding": null,
      "mode": handover?["mode"],
      "state": handover?["state"],
      "seller": _person(invoice["seller"] as String?),
      "chat": "",
      "date": invoice["opened"],
      "updated": _updated(invoice),
    }..removeWhere((key, _) => key == "section" && !section);
  }

  // ---------------------------------------------------------------- sales.detail

  /// `sales.detail {reference}` (SA-30 to SA-35): a ticket code in any case, or an invoice id.
  /// [seller] limits it to one person's sales, the rest being `sale_not_found` (SA-11).
  Map<String, Object?> detail(String reference, {String? seller}) {
    final invoice = _find(reference, seller: seller);
    final document = _pos.document(invoice);
    final status = invoice["status"] as String;
    final open = status == "open";
    final closed = status == "closed";
    final language = _business.language;
    final payment = document["payment"] as Map?;

    return {
      "id": invoice["id"],
      "source": open ? "invoice" : "ticket",
      "ticket": invoice["ticket"],
      // The cloud's document statuses: a charged sale is `completed`.
      "status": closed ? "completed" : status,
      ..._standing(measure(invoice), language),
      "channel": SaleChannels.pos,
      "origin": {"kind": "pos", "channel": SaleChannels.pos, "terminal": _terminal(invoice["device"] as String)},
      "customer": null,
      "chat": null,
      "seller": {"kind": "user", "name": _person(invoice["seller"] as String?)},
      "note": invoice["note"],
      "currency": invoice["currency"],
      "units": document["units"],
      "subtotal": document["subtotal"],
      "tax": document["tax"],
      "taxes": document["taxes"],
      "total": document["total"],
      "payment": {
        ...?payment?.cast<String, Object?>(),
        "collected": null,
        "outstanding": null,
        // Proofs come from conversations (SA-33).
        "proofs": const <Object?>[],
      },
      "fulfillment": closed ? _handoverDetail(invoice, language) : null,
      "held": document["held"],
      "reservations": open ? _holds(invoice["id"] as String) : null,
      "items": [for (final line in (document["items"] as List).cast<Map<String, Object?>>()) _item(line, open)],
      "opened": invoice["opened"],
      "closed": invoice["closed"],
      "date": invoice["closed"] ?? invoice["opened"],
      "updated": _updated(invoice),
    };
  }

  // ---------------------------------------------------------------- sales.fulfil

  /// `sales.fulfil {id, mode?, state?, note?}` (SA-20 to SA-24): the handover of a charged ticket,
  /// answered as its row **with its section**.
  Map<String, Object?> fulfil(String id, {
    Object? mode,
    Object? state,
    Object? note,
    String? seller,
    required String actor,
    String? device,
  }) => _store.write((db) {
    final invoice = _find(id, seller: seller, byCode: false);
    if (invoice["status"] != "closed") throw const EngineFailure("not_a_ticket");

    if (mode != null && mode is! String) throw const EngineFailure(ErrorCodes.invalidField, {"field": "mode"});
    if (state != null && state is! String) throw const EngineFailure(ErrorCodes.invalidField, {"field": "state"});
    if (note != null && note is! String) throw const EngineFailure(ErrorCodes.invalidField, {"field": "note"});
    if (mode == null && state == null) throw const EngineFailure("nothing_to_change");

    final current = _handover(invoice);
    final nextMode = (mode ?? current["mode"]) as String?;
    final allowed = Handover.modes[nextMode]?.$1;
    // Naming only the mode leaves it at that mode's first state (SA-22).
    final nextState = (state ?? (mode != null ? allowed?.first : current["state"])) as String?;
    if (allowed == null || !allowed.contains(nextState)) throw const EngineFailure("invalid_state");

    final text = (note as String?)?.replaceAll(RegExp(r"\p{Cc}", unicode: true), " ").trim() ?? "";
    if (text.length > PosLimits.maxNote) throw const EngineFailure(ErrorCodes.invalidField, {"field": "note"});

    final stamp = _clock.tick();
    final handover = {
      "mode": nextMode,
      "state": nextState,
      "at": _instant(_now()),
      "by": actor,
      // A blank note doesn't erase the stored one (SA-23).
      "note": text.isEmpty ? current["note"] : text,
      "stored": true,
    };

    db.execute("UPDATE pos_invoices SET handover = ?, updated_hlc = ? WHERE id = ?",
      [jsonEncode(handover), stamp.pack(), invoice["id"]]);
    Oplog(db).append(hlc: stamp, entity: "pos_invoice", entityId: invoice["id"] as String, kind: "handover",
      payload: {"mode": nextMode, "state": nextState, "note": ?(text.isEmpty ? null : text)},
      actor: actor, device: device);

    final after = _db.select("SELECT * FROM pos_invoices WHERE id = ?", [invoice["id"]]).first;
    announce(db, after, language: _business.language, at: _now());

    return row(after, section: true);
  });

  // ---------------------------------------------------------------- measuring

  /// [invoice]'s stage and since when (SA-3), or null when it is on neither list (cancelled).
  /// The same rule as [_stageSql] and [_sinceSql], which page the board.
  static (String, String?)? measure(Row invoice) {
    switch (invoice["status"]) {
      case "open":
        return (SaleStages.open, invoice["opened"] as String?);
      case "closed":
        final handover = _handover(invoice);
        final since = (handover["at"] ?? invoice["closed"]) as String?;
        if ((handover["state"] ?? Handover.done) == Handover.done) return (SaleStages.completed, since);

        return (switch (handover["mode"]) {
          Handover.delivery => handover["state"] == Handover.dispatched ? SaleStages.transit : SaleStages.shipping,
          Handover.pickup => SaleStages.pickup,
          _ => SaleStages.handover,
        }, since);
      default:
        return null;
    }
  }

  static const _stageSql = """
    CASE
      WHEN i.status = 'open' THEN 'open'
      WHEN coalesce(json_extract(i.handover, '\$.state'), 'done') = 'done' THEN 'completed'
      WHEN json_extract(i.handover, '\$.mode') = 'delivery'
        THEN CASE json_extract(i.handover, '\$.state') WHEN 'dispatched' THEN 'transit' ELSE 'shipping' END
      WHEN json_extract(i.handover, '\$.mode') = 'pickup' THEN 'pickup'
      ELSE 'handover'
    END""";

  static const _sinceSql = """
    CASE WHEN i.status = 'open' THEN i.opened ELSE coalesce(json_extract(i.handover, '\$.at'), i.closed) END""";

  /// `sale/progress` for [invoice] as it now stands (`sales.md`, events): the `SaleProgressModel`
  /// shape, every key present, `section: null` once it left both lists. Only its seller's sessions
  /// and those holding [viewAll] receive it (SA-11).
  static void announce(Database db, Row invoice, {required String language, required DateTime at}) =>
    EventLog.append(db, Events.saleProgress, {
      "id": invoice["id"],
      "source": invoice["status"] == "open" ? "invoice" : "ticket",
      "ticket": invoice["ticket"],
      "chat": null,
      ..._standing(measure(invoice), language),
    }, at: at, permission: "sales", owner: invoice["seller"] as String?, overrides: viewAll);

  /// `stage`, `label`, `section`, `level`, `attention` and `since` of a measurement.
  static Map<String, Object?> _standing((String, String?)? measured, String language) {
    final kind = measured == null ? null : SaleStages.kinds[measured.$1];

    return {
      "stage": measured?.$1,
      "label": measured == null ? null : SaleStages.name(measured.$1, language),
      "section": kind?.$1,
      "level": kind?.$2,
      "attention": kind?.$3 ?? false,
      "since": measured?.$2,
    };
  }

  static Map<String, Object?> _handover(Row invoice) => invoice["handover"] == null
    ? const {}
    : (jsonDecode(invoice["handover"] as String) as Map).cast<String, Object?>();

  // ---------------------------------------------------------------- internals

  /// The invoice [reference] names (a ticket code in any case, or its id), refused as
  /// `sale_not_found` when it doesn't exist, isn't [seller]'s, or was cancelled before anything
  /// was sold on it.
  Row _find(String reference, {String? seller, bool byCode = true}) {
    final row = _db.select(
      "SELECT * FROM pos_invoices WHERE (id = ? OR (? AND ticket = ?)) AND (? IS NULL OR seller = ?) LIMIT 1",
      [reference, byCode ? 1 : 0, reference, seller, seller],
    ).firstOrNull;
    if (row == null) throw const EngineFailure("sale_not_found");

    return row;
  }

  Map<String, Object?> _handoverDetail(Row invoice, String language) {
    final handover = _handover(invoice);

    return {
      "mode": handover["mode"],
      "modeName": Handover.modeName(handover["mode"] as String?, language),
      "state": handover["state"],
      "stateName": Handover.stateName(handover["state"] as String?, language),
      "at": handover["at"],
      "by": _person(handover["by"] as String?),
      "note": handover["note"],
      // Whether somebody said it (`sales.fulfil`), or it is the counter's own reading: handed over
      // on the spot.
      "stored": handover["stored"] == true,
    };
  }

  /// A line of the detail (SA-31): an open invoice says what the shelf is doing for it.
  Map<String, Object?> _item(Map<String, Object?> line, bool open) {
    final productId = line["productId"] as String?;
    final tracked = line["tracked"] == true;
    final product = productId == null
      ? null
      : _db.select("SELECT deleted FROM inventory_records WHERE id = ?", [productId]).firstOrNull;
    final balance = open && tracked
      ? _db.select("SELECT on_hand - reserved AS available FROM stock_balances WHERE product_id = ?", [productId])
          .firstOrNull
      : null;

    return {
      "productId": productId ?? "",
      "sku": line["sku"],
      "name": line["name"],
      "qty": line["qty"],
      "price": line["price"],
      "list": line["list"],
      "discount": line["discount"],
      "subtotal": line["subtotal"],
      "taxRate": line["taxRate"],
      "tax": line["tax"],
      "total": line["total"],
      "held": line["held"],
      // A tracked line of an open invoice is units set aside; holding fewer is a hold somebody
      // shrank from the stock screen (ST-22), which the panel shows.
      "state": open && tracked ? "reserved" : "",
      "available": balance?["available"],
      "gone": productId != null && (product == null || product["deleted"] == 1),
    };
  }

  /// The invoice's standing holds (SA-32), as the app's `SaleHoldModel` reads them.
  List<Map<String, Object?>> _holds(String invoiceId) => [
    for (final hold in _db.select(
      "SELECT * FROM stock_holds WHERE owner_kind = 'invoice' AND owner_id = ? AND status = 'active' "
      "ORDER BY created, id",
      [invoiceId],
    ))
      {
        "id": hold["id"],
        "tableId": hold["table_id"],
        "productId": hold["product_id"],
        "sku": hold["sku"],
        "qty": hold["qty"],
        // The cloud's word for a hold that stands.
        "status": "pending",
        "expiresAt": hold["expires"],
        "createdAt": hold["created"],
      },
  ];

  /// A person by name, never by id.
  String? _person(String? account) {
    if (account == null) return null;

    final row = _db.select("SELECT first_name, last_name FROM accounts WHERE id = ?", [account]).firstOrNull;

    return row == null ? null : "${row["first_name"]} ${row["last_name"]}".trim();
  }

  String? _terminal(String device) =>
    _db.select("SELECT name FROM devices WHERE id = ?", [device]).firstOrNull?["name"] as String?;

  /// The last change of [invoice], from its clock stamp.
  static String _updated(Row invoice) =>
    _instant(DateTime.fromMillisecondsSinceEpoch(Hlc.parse(invoice["updated_hlc"] as String).millis, isUtc: true));

  static String _instant(DateTime at) =>
    DateTime.fromMillisecondsSinceEpoch(at.millisecondsSinceEpoch, isUtc: true).toIso8601String();
}
