import 'dart:convert';

import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../audit/audit_log.dart';
import '../../failure.dart';
import '../../ids.dart';
import '../../oplog/hlc.dart';
import '../../oplog/oplog.dart';
import '../../storage/store.dart';
import '../business/business.dart';
import '../business/zones.dart';
import '../pos/pos.dart';
import 'rails.dart';

/// The company's money (`money.md`): payments recorded by hand, the summary, the receivables and
/// the exchange currencies.
///
/// It **adds nothing into anything else**: what the register took is read from the closed tickets
/// (`pos.md`) and what was recorded by hand from `money_payments`, and the two are only put side by
/// side on the way out. Money is in minor units of the company's main currency (M-5).
final class Finance {
  Finance(this._store, this._clock, this._business, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Store _store;
  final HlcClock _clock;
  final Business _business;
  final DateTime Function() _now;

  Database get _db => _store.db;

  /// Whether a sale can go on the store's tab. Deferred offline (money.receivable): no settlement
  /// kind with `credit` is offered (POS-33), so no receivable exists and nothing settles one. The
  /// rules below still read the flags, for the day credit is decided.
  static const credit = false;

  static const _recorded = "recorded";
  static const _voided = "voided";

  /// Concept codes that pay a credit ticket down (M-7), read from the vocabulary's flag.
  static final _settling = [
    for (final MapEntry(key: concept, value: kind) in MoneyConcepts.kinds.entries) if (kind.$3) concept,
  ];

  // ---------------------------------------------------------------- money.catalog

  /// `money.catalog`: the concepts each way and the settlement kinds, in the company's language.
  Map<String, Object?> catalog() {
    final language = _business.language;

    return {
      "concepts": {
        "in": MoneyConcepts.rows(language, direction: MoneyConcepts.incoming, credit: credit),
        "out": MoneyConcepts.rows(language, direction: MoneyConcepts.outgoing, credit: credit),
      },
      "methods": Settlements.rows(language, credit: credit),
    };
  }

  // ---------------------------------------------------------------- money.payments

  /// `money.payments.record` (M-1 to M-9). [args] are the op's; the answer is the payment.
  Map<String, Object?> record(Map<String, Object?> args, {required String actor, String? device}) =>
    _store.write((db) {
      if (args.containsKey("direction")) throw const EngineFailure(ErrorCodes.badRequest);

      final concept = conceptOf(args["concept"]);
      final (direction, allowsTicket, settles, _) = MoneyConcepts.kinds[concept]!;

      final amount = args["amount"];
      if (amount is! int || amount <= 0 || amount >= 1000000000000000) throw const EngineFailure("invalid_amount");

      final account = _accountOf(args["accountId"]);
      final method = args["method"] ?? account?.$2;
      final kind = method is String ? Settlements.kinds[method] : null;
      if (kind == null || (kind.$3 && !credit)) throw const EngineFailure("unknown_method");
      if (account != null && account.$2 != method) throw const EngineFailure("method_mismatch");

      final reference = _text(args["reference"], "reference", MoneyLimits.maxReference);
      final note = _text(args["note"], "note", MoneyLimits.maxNote);
      final counterpart = _counterpart(args["counterpart"]);
      final date = _date(args["date"]);
      final ticket = _ticket(args["ticket"], allowsTicket: allowsTicket, settles: settles, amount: amount);

      final id = newId();
      final stamp = _clock.tick();
      final created = _instant(_now());

      db.execute(
        "INSERT INTO money_payments (id, concept, direction, amount, currency, method, account_id, reference, "
        "counterpart, ticket_id, note, date, registered_by, device, created, created_hlc, updated_hlc) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [id, concept, direction, amount, _business.currency, method, account?.$1, reference,
          counterpart == null ? null : jsonEncode(counterpart), ticket, note, date, actor, device, created,
          stamp.pack(), stamp.pack()],
      );
      Oplog(db).append(hlc: stamp, entity: "money_payment", entityId: id, kind: "recorded",
        payload: {"concept": concept, "amount": amount}, actor: actor, device: device);

      return _payment(_row(id));
    });

  /// `money.payments.void {id, reason?}` (M-8): the row stays, `voided`, and stops counting
  /// everywhere; voiding a settlement gives its ticket the debt back, since what is owed is
  /// measured from the recorded settlements. Every void goes to the audit log.
  Map<String, Object?> voidPayment(String id, {Object? reason, required String actor, String? device}) =>
    _store.write((db) {
      final row = _row(id);
      if (row["status"] == _voided) throw const EngineFailure("already_voided");

      final why = _text(reason, "reason", MoneyLimits.maxReason);
      final stamp = _clock.tick();

      db.execute(
        "UPDATE money_payments SET status = 'voided', void_reason = ?, voided_by = ?, voided_at = ?, updated_hlc = ? "
        "WHERE id = ?",
        [why, actor, _instant(_now()), stamp.pack(), id],
      );
      Oplog(db).append(hlc: stamp, entity: "money_payment", entityId: id, kind: "voided", actor: actor,
        device: device);
      AuditLog(db, now: _now).append(AuditKinds.paymentVoided, actor: actor, device: device, data: {
        "payment": id,
        "concept": row["concept"],
        "amount": row["amount"],
        "currency": row["currency"],
        "reason": why,
      });

      return _payment(_row(id));
    });

  /// `money.payments.search` (M-10): `date` newest first, then `id`. `totals` are over the whole
  /// filter and never count a voided payment, whatever [status] lists.
  Map<String, Object?> search({
    required int page,
    required int size,
    String? direction,
    String? concept,
    String? method,
    String status = "all",
  }) {
    if (direction != null && direction != MoneyConcepts.incoming && direction != MoneyConcepts.outgoing) {
      throw const EngineFailure(ErrorCodes.invalidField, {"field": "direction"});
    }
    if (status != "all" && status != _recorded && status != _voided) {
      throw const EngineFailure(ErrorCodes.invalidField, {"field": "status"});
    }

    const filter = "(? IS NULL OR p.direction = ?) AND (? IS NULL OR p.concept = ?) AND (? IS NULL OR p.method = ?)";
    final params = [direction, direction, concept, concept, method, method];
    final listed = status == "all" ? null : status;

    final total = _db.select(
      "SELECT count(*) AS n FROM money_payments p WHERE $filter AND (? IS NULL OR p.status = ?)",
      [...params, listed, listed],
    ).first["n"] as int;
    final rows = _db.select(
      "SELECT p.* FROM money_payments p WHERE $filter AND (? IS NULL OR p.status = ?) "
      "ORDER BY p.date DESC, p.id DESC LIMIT ? OFFSET ?",
      [...params, listed, listed, size, (page - 1) * size],
    );
    final sums = {
      for (final row in _db.select(
        "SELECT p.direction, count(*) AS n, sum(p.amount) AS total FROM money_payments p "
        "WHERE $filter AND p.status = 'recorded' GROUP BY p.direction",
        params,
      ))
        row["direction"] as String: {"count": row["n"], "total": row["total"]},
    };

    return {
      "total": total,
      "page": page,
      "size": size,
      "totals": {
        for (final way in const [MoneyConcepts.incoming, MoneyConcepts.outgoing])
          way: sums[way] ?? const {"count": 0, "total": 0},
      },
      "data": [for (final row in rows) _payment(row, flat: true)],
    };
  }

  /// The concept [raw] names, refused as `invalid_field` when it isn't one.
  static String conceptOf(Object? raw) {
    if (raw == null) throw const EngineFailure(ErrorCodes.required, {"field": "concept"});
    if (raw is! String || !MoneyConcepts.kinds.containsKey(raw)) {
      throw const EngineFailure(ErrorCodes.invalidField, {"field": "concept"});
    }

    return raw;
  }

  // ---------------------------------------------------------------- money.summary

  /// `money.summary {from?}` (M-20 to M-28): the window `[from, now]`, today in the company's zone
  /// when [from] is null.
  Map<String, Object?> summary({DateTime? from}) {
    final now = _now();
    if (from != null && from.isAfter(now)) throw const EngineFailure(ErrorCodes.invalidField, {"field": "from"});

    final start = _instant(from ?? Zones.dayOf(_business.timezone, now).$1);
    final end = _instant(now);
    final language = _business.language;

    // The register: closed tickets of the window, by how they were paid (M-21, M-24).
    final tickets = _tickets("i.closed >= ? AND i.closed <= ?", [start, end]);
    final register = <String, (int, int)>{};
    var (salesCount, salesTotal, creditCount, creditOwed) = (0, 0, 0, 0);

    for (final ticket in tickets.values) {
      if (ticket.credit) {
        creditCount += 1;
        creditOwed += ticket.total - _collected(ticket.id).clamp(0, ticket.total);
        continue;
      }

      final (count, total) = register[ticket.method] ?? (0, 0);
      register[ticket.method] = (count + 1, total + ticket.total);
      salesCount += 1;
      salesTotal += ticket.total;
    }

    // What was recorded by hand in the window (M-22, M-23, M-27).
    const recorded = "status = 'recorded' AND date >= ? AND date <= ?";
    final ways = {
      for (final row in _db.select(
        "SELECT direction, count(*) AS n, sum(amount) AS total FROM money_payments WHERE $recorded GROUP BY direction",
        [start, end],
      ))
        row["direction"] as String: (row["n"] as int, row["total"] as int),
    };
    final (paymentsIn, paidIn) = ways[MoneyConcepts.incoming] ?? (0, 0);
    final (paymentsOut, paidOut) = ways[MoneyConcepts.outgoing] ?? (0, 0);

    final byMethod = <String, ({int incoming, int outgoing, int count})>{
      for (final MapEntry(key: method, value: (count, total)) in register.entries)
        method: (incoming: total, outgoing: 0, count: count),
    };
    for (final row in _db.select(
      "SELECT method, direction, count(*) AS n, sum(amount) AS total FROM money_payments WHERE $recorded "
      "GROUP BY method, direction",
      [start, end],
    )) {
      final method = row["method"] as String;
      final current = byMethod[method] ?? (incoming: 0, outgoing: 0, count: 0);
      final total = row["total"] as int;
      final incoming = row["direction"] == MoneyConcepts.incoming;

      byMethod[method] = (
        incoming: current.incoming + (incoming ? total : 0),
        outgoing: current.outgoing + (incoming ? 0 : total),
        count: current.count + (row["n"] as int),
      );
    }

    final income = salesTotal + paidIn;

    return {
      "from": start,
      "to": end,
      "currency": _business.currency,
      "income": {
        "sales": {"count": salesCount, "total": salesTotal},
        "payments": {"count": paymentsIn, "total": paidIn},
        "total": income,
      },
      "expenses": {"count": paymentsOut, "total": paidOut},
      "credit": {"count": creditCount, "total": creditOwed},
      "net": income - paidOut,
      // In the vocabulary's order, so the breakdown doesn't reshuffle between two reads (M-26). The
      // credit kind moves no money and is never listed.
      "methods": [
        for (final method in [
          ...Settlements.kinds.keys.where(byMethod.containsKey),
          ...byMethod.keys.where((method) => !Settlements.kinds.containsKey(method)),
        ])
          if (Settlements.kinds[method]?.$3 != true)
            {
              "method": method,
              "name": Settlements.name(method, language),
              "in": byMethod[method]!.incoming,
              "out": byMethod[method]!.outgoing,
              "net": byMethod[method]!.incoming - byMethod[method]!.outgoing,
              "count": byMethod[method]!.count,
            },
      ],
      // Largest first, as the cloud answers them; then by code, so a tie has one order.
      "concepts": [
        for (final row in _db.select(
          "SELECT concept, direction, count(*) AS n, sum(amount) AS total FROM money_payments WHERE $recorded "
          "GROUP BY concept, direction ORDER BY total DESC, concept",
          [start, end],
        ))
          {
            "concept": row["concept"],
            "name": MoneyConcepts.name(row["concept"] as String, language),
            "direction": row["direction"],
            "count": row["n"],
            "total": row["total"],
          },
      ],
    };
  }

  // ---------------------------------------------------------------- money.receivables

  /// `money.receivables {page, size, open}` (M-30 to M-32): the credit tickets, newest first.
  /// Offline there are none while credit is deferred; the read is the rule, measured.
  Map<String, Object?> receivables({required int page, required int size, required bool open}) {
    final rows = [
      for (final ticket in _tickets("json_extract(i.payment, '\$.credit') = 1", const []).values)
        if (ticket.credit)
          () {
            final collected = _collected(ticket.id);
            return (ticket: ticket, collected: collected, outstanding: (ticket.total - collected).clamp(0, ticket.total));
          }(),
    ]
      ..retainWhere((row) => !open || row.outstanding > 0)
      ..sort((a, b) {
        final byDate = b.ticket.closed.compareTo(a.ticket.closed);
        return byDate != 0 ? byDate : b.ticket.id.compareTo(a.ticket.id);
      });

    return {
      "total": rows.length,
      "page": page,
      "size": size,
      "currency": _business.currency,
      "totals": {
        "count": rows.length,
        "sold": rows.fold<int>(0, (sum, row) => sum + row.ticket.total),
        "collected": rows.fold<int>(0, (sum, row) => sum + row.collected),
        "outstanding": rows.fold<int>(0, (sum, row) => sum + row.outstanding),
      },
      "data": [
        for (final row in rows.skip((page - 1) * size).take(size))
          {
            "id": row.ticket.id,
            "ticket": row.ticket.code,
            "channel": SaleChannels.pos,
            // A counter sale has no customer (`pos.md` POS-33, `money.md` Open question 1).
            "customer": null,
            "seller": _person(row.ticket.seller),
            "total": row.ticket.total,
            "collected": row.collected,
            "outstanding": row.outstanding,
            "currency": row.ticket.currency,
            "date": row.ticket.closed,
          },
      ],
    };
  }

  // ---------------------------------------------------------------- money.currencies

  /// `money.currencies.get` (M-50 to M-52). `official` needs a rate feed on the internet, so it is
  /// always null here and only custom rates have a `rate`.
  Map<String, Object?> currencies() => {
    "currency": _business.currency,
    "currencies": [
      for (final row in _db.select("SELECT * FROM money_currencies WHERE active = 1 ORDER BY currency"))
        {
          "currency": row["currency"],
          "mode": row["mode"],
          "rate": row["mode"] == "custom" ? row["custom"] : null,
          "official": null,
          "custom": row["custom"],
          "updated": null,
        },
    ],
  };

  /// `money.currencies.save {currency, mode, rate?}`: adds an exchange currency or changes its rate.
  /// `rate` counts only in `custom` mode; switching back to `official` keeps the custom figure
  /// (M-53).
  Map<String, Object?> saveCurrency({
    required String currency,
    required Object? mode,
    Object? rate,
    required String actor,
    String? device,
  }) => _store.write((db) {
    final code = _exchange(currency);
    if (mode != "official" && mode != "custom") throw const EngineFailure(ErrorCodes.invalidField, {"field": "mode"});

    final custom = mode == "custom" ? _rate(rate) : null;
    final stamp = _clock.tick();

    db.execute(
      "INSERT INTO money_currencies (currency, mode, custom, active, updated_hlc) VALUES (?, ?, ?, 1, ?) "
      "ON CONFLICT (currency) DO UPDATE SET mode = excluded.mode, custom = coalesce(excluded.custom, custom), "
      "active = 1, updated_hlc = excluded.updated_hlc",
      [code, mode, custom, stamp.pack()],
    );
    Oplog(db).append(hlc: stamp, entity: "money_currency", entityId: code, kind: "saved",
      payload: {"mode": mode, "custom": ?custom}, actor: actor, device: device);

    return currencies();
  });

  /// `money.currencies.remove {currency}`: taken off, not deleted, so adding it again keeps its
  /// figure. `in_use` (an account in that currency) arrives with the accounts.
  Map<String, Object?> removeCurrency(String currency, {required String actor, String? device}) =>
    _store.write((db) {
      final code = currency.trim().toUpperCase();
      final found = _db.select("SELECT 1 FROM money_currencies WHERE currency = ? AND active = 1", [code]);
      if (found.isEmpty) throw const EngineFailure(ErrorCodes.notFound);
      if (_db.select("SELECT 1 FROM money_methods WHERE currency = ? AND active = 1", [code]).isNotEmpty) {
        throw const EngineFailure("in_use");
      }

      final stamp = _clock.tick();
      db.execute("UPDATE money_currencies SET active = 0, updated_hlc = ? WHERE currency = ?", [stamp.pack(), code]);
      Oplog(db).append(hlc: stamp, entity: "money_currency", entityId: code, kind: "removed", actor: actor,
        device: device);

      return currencies();
    });

  // ---------------------------------------------------------------- internals

  /// M-4: the active account [raw] names, as `(id, settlement kind)`; null when none is named.
  (String, String)? _accountOf(Object? raw) {
    if (raw == null) return null;

    final row = raw is String
      ? _db.select("SELECT id, method FROM money_methods WHERE id = ? AND active = 1", [raw]).firstOrNull
      : null;
    if (row == null) throw const EngineFailure("unknown_account");

    return (row["id"] as String, row["method"] as String);
  }

  /// What a payment's account is called: the company's label, else its rail's name. A removed
  /// account still reads (M-44).
  String? _accountLabel(String? id) {
    if (id == null) return null;

    final row = _db.select("SELECT code, label FROM money_methods WHERE id = ?", [id]).firstOrNull;
    if (row == null) return null;

    final code = row["code"] as String;

    return row["label"] as String? ??
      (Rails.kinds.containsKey(code) ? Rails.row(code, _business.language)["name"] as String? : code);
  }

  Row _row(String id) {
    final row = _db.select(
      "SELECT p.*, i.ticket AS ticket_code FROM money_payments p LEFT JOIN pos_invoices i ON i.id = p.ticket_id "
      "WHERE p.id = ?",
      [id],
    ).firstOrNull;
    if (row == null) throw const EngineFailure(ErrorCodes.notFound);

    return row;
  }

  /// A payment as the app's `MoneyPayment` reads it. [flat] is a listing's row: the counterpart
  /// read down to one value, as the cloud's search answers it.
  Map<String, Object?> _payment(Row row, {bool flat = false}) {
    final language = _business.language;
    final counterpart = row["counterpart"] == null
      ? null
      : (jsonDecode(row["counterpart"] as String) as Map).cast<String, Object?>();
    final code = row.containsKey("ticket_code")
      ? row["ticket_code"]
      : row["ticket_id"] == null
        ? null
        : _db.select("SELECT ticket FROM pos_invoices WHERE id = ?", [row["ticket_id"]]).firstOrNull?["ticket"];

    return {
      "id": row["id"],
      "direction": row["direction"],
      "concept": row["concept"],
      "conceptName": MoneyConcepts.name(row["concept"] as String, language),
      "amount": row["amount"],
      "currency": row["currency"],
      "method": row["method"],
      "methodName": Settlements.name(row["method"] as String, language),
      if (!flat) "accountId": row["account_id"],
      "account": _accountLabel(row["account_id"] as String?),
      "reference": row["reference"],
      "counterpart": flat ? (counterpart?["name"] ?? counterpart?["contact"]) : counterpart,
      "ticket": code,
      "note": row["note"],
      "status": row["status"],
      if (!flat)
        "voided": row["status"] == _voided
          ? {"at": row["voided_at"], "by": _person(row["voided_by"] as String?), "reason": row["void_reason"]}
          : null,
      "registeredBy": _person(row["registered_by"] as String?),
      "date": row["date"],
      if (!flat) "created": row["created"],
    };
  }

  /// The closed ticket a payment names (M-6, M-7), as its invoice id; null when it names none.
  String? _ticket(Object? raw, {required bool allowsTicket, required bool settles, required int amount}) {
    final code = _text(raw, "ticket", 64);

    if (code == null) {
      if (settles) throw const EngineFailure("ticket_required");
      return null;
    }
    if (!allowsTicket) throw const EngineFailure("ticket_not_allowed");

    final row = _db.select("SELECT id FROM pos_invoices WHERE ticket = ? AND status = 'closed'", [code]).firstOrNull;
    if (row == null) throw const EngineFailure("sale_not_found");

    final id = row["id"] as String;
    if (settles) {
      final ticket = _tickets("i.id = ?", [id])[id]!;
      if (!ticket.credit) throw const EngineFailure("not_credit");

      final outstanding = (ticket.total - _collected(id)).clamp(0, ticket.total);
      if (amount > outstanding) throw EngineFailure("exceeds_outstanding", {"outstanding": outstanding});
    }

    return id;
  }

  /// The closed tickets [where] picks, each with its total added up from its lines (POS-20).
  Map<String, _Ticket> _tickets(String where, List<Object?> params) {
    final tickets = <String, _Ticket>{};

    for (final line in _db.select(
      "SELECT i.id, i.ticket, i.seller, i.closed, i.currency, i.payment, l.price, l.qty, l.tax_rate "
      "FROM pos_invoices i JOIN pos_lines l ON l.invoice_id = i.id WHERE i.status = 'closed' AND $where",
      params,
    )) {
      final id = line["id"] as String;
      final ticket = tickets[id] ??= () {
        final payment = jsonDecode(line["payment"] as String) as Map;
        return _Ticket(
          id: id,
          code: line["ticket"] as String,
          seller: line["seller"] as String,
          closed: line["closed"] as String,
          currency: line["currency"] as String,
          method: payment["method"] as String,
          credit: payment["credit"] == true,
        );
      }();

      ticket.total += Pos.lineTotal(line["price"] as int, line["qty"] as int, line["tax_rate"] as String);
    }

    return tickets;
  }

  /// What the recorded settlements of ticket [id] add up to (M-30).
  int _collected(String id) => _db.select(
    "SELECT coalesce(sum(amount), 0) AS n FROM money_payments WHERE ticket_id = ? AND status = 'recorded' "
    "AND concept IN (${List.filled(_settling.length, "?").join(", ")})",
    [id, ..._settling],
  ).first["n"] as int;

  /// An exchange currency (M-42): a fiat currency of the catalogue that isn't the main one.
  String _exchange(String raw) {
    final code = raw.trim().toUpperCase();
    final row = Catalogs.currencyRows.where((row) => row["code"] == code).firstOrNull;

    if (row == null || row["type"] != "fiat") throw const EngineFailure("unknown_currency");
    if (code == _business.currency) throw const EngineFailure("is_main");

    return code;
  }

  /// A custom rate (M-53): a positive number, `1 main = rate`.
  static double _rate(Object? raw) {
    final value = switch (raw) {
      final num number => number.toDouble(),
      final String text => double.tryParse(text.trim()),
      _ => null,
    };
    if (value == null || !value.isFinite || value <= 0 || value >= 1e12) throw const EngineFailure("invalid_rate");

    return value;
  }

  /// When the money moved (M-3): now when not given, never more than [MoneyLimits.futureSkew] ahead.
  String _date(Object? raw) {
    final now = _now();
    if (raw == null) return _instant(now);

    final date = raw is String ? DateTime.tryParse(raw.trim()) : null;
    if (date == null) throw const EngineFailure(ErrorCodes.invalidField, {"field": "date"});
    if (date.isAfter(now.add(MoneyLimits.futureSkew))) throw const EngineFailure("future_date");

    return _instant(date);
  }

  /// `{name?, contact?}`, each trimmed; null when neither has anything (M-9).
  static Map<String, String>? _counterpart(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) throw const EngineFailure(ErrorCodes.invalidField, {"field": "counterpart"});

    final name = _text(raw["name"], "counterpart", MoneyLimits.maxCounterpart);
    final contact = _text(raw["contact"], "counterpart", MoneyLimits.maxCounterpart);
    if (name == null && contact == null) return null;

    return {"name": ?name, "contact": ?contact};
  }

  /// An optional text, trimmed, control characters off; null when blank (M-9).
  static String? _text(Object? raw, String field, int max) {
    if (raw == null) return null;
    if (raw is! String) throw EngineFailure(ErrorCodes.invalidField, {"field": field});

    final text = raw.replaceAll(RegExp(r"\p{Cc}", unicode: true), " ").trim();
    if (text.length > max) throw EngineFailure(ErrorCodes.invalidField, {"field": field});

    return text.isEmpty ? null : text;
  }

  /// A person by name, never by id.
  String? _person(String? account) {
    if (account == null) return null;

    final row = _db.select("SELECT first_name, last_name FROM accounts WHERE id = ?", [account]).firstOrNull;

    return row == null ? null : "${row["first_name"]} ${row["last_name"]}".trim();
  }

  /// Instants to the millisecond, so stored ones compare as text.
  static String _instant(DateTime at) =>
    DateTime.fromMillisecondsSinceEpoch(at.millisecondsSinceEpoch, isUtc: true).toIso8601String();
}

/// A closed ticket as the money screen reads it.
final class _Ticket {
  _Ticket({
    required this.id,
    required this.code,
    required this.seller,
    required this.closed,
    required this.currency,
    required this.method,
    required this.credit,
  });

  final String id;
  final String code;
  final String seller;
  final String closed;
  final String currency;
  final String method;
  final bool credit;
  int total = 0;
}
