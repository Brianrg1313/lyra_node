import 'dart:typed_data';

import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../audit/audit_log.dart';
import '../../crypto/sealed.dart';
import '../../failure.dart';
import '../../ids.dart';
import '../../oplog/hlc.dart';
import '../../oplog/oplog.dart';
import '../../storage/store.dart';
import '../business/business.dart';
import '../pos/money.dart';
import 'finance.dart';
import 'rails.dart';

/// A create or an edit checked and its account sealed, ready for [MoneyMethods.save]. Made
/// outside the write because sealing is asynchronous and a write isn't.
final class MethodDraft {
  const MethodDraft._(this.id, this.code, this.columns, {required this.isNew});

  final String id;
  final String code;
  final bool isNew;

  /// The columns to write, by name (`sealed` included when the account changed).
  final Map<String, Object?> columns;
}

/// The company's payment accounts (`money.md` money.method, M-40 to M-46).
///
/// `holder`, `document` and `account` are sealed with the `payments` key (M-45): reading the list,
/// or writing an account that has any of them, takes the session's key, and without one answers
/// `sealed_locked`, which the person clears by signing in again with their password. Reading them
/// is audited (plan §6.6).
final class MoneyMethods {
  MoneyMethods(this._store, this._clock, this._business, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// How many active accounts a company keeps: a picker nobody scrolls is no help.
  static const max = 40;

  /// Each text column's ceiling.
  static const limits = {
    "label": 64,
    "holder": 120,
    "document": 40,
    "institution": 80,
    "account": 120,
    "instructions": 255,
  };

  static const _sealedColumns = ["holder", "document", "account"];
  static const _commonColumns = ["label", "instructions"];

  final Store _store;
  final HlcClock _clock;
  final Business _business;
  final DateTime Function() _now;

  Database get _db => _store.db;

  // ---------------------------------------------------------------- money.methods.rails

  /// `money.methods.rails` (M-40): the rails offered in the company's country, each one's sheet,
  /// and the lists their closed fields pick from.
  Map<String, Object?> rails() {
    final country = _business.country;
    final options = Rails.options(country);
    final rails = Rails.available(country, _business.language, credit: Finance.credit);

    return {
      "country": country,
      "methods": rails,
      "fields": {
        for (final rail in rails)
          rail["code"]! as String: [for (final field in Rails.sheet(rail["code"]! as String, options)) Rails.fieldJson(field)],
      },
      "options": options,
    };
  }

  // ---------------------------------------------------------------- money.methods.list

  /// `money.methods.list`: the active accounts by `position`, and the sheet of each rail on it.
  Future<Map<String, Object?>> list(Uint8List? key, {required String actor, String? device}) async {
    final sealedKey = _need(key);
    final rows = _db.select("SELECT * FROM money_methods WHERE active = 1 ORDER BY position, created, id");
    final options = Rails.options(_business.country);
    final methods = [
      for (final row in rows) _answer(row, await _open(sealedKey, row), options),
    ];

    if (rows.isNotEmpty) {
      _store.write((db) => AuditLog(db, now: _now).append(AuditKinds.sealedRead, actor: actor, device: device, data: {
        "scope": SealedScope.payments.name,
        "what": "money.methods",
        "count": rows.length,
      }));
    }

    return {
      "methods": methods,
      "fields": {
        for (final code in {for (final row in rows) row["code"] as String})
          code: [for (final field in Rails.sheet(code, options)) Rails.fieldJson(field)],
      },
    };
  }

  // ---------------------------------------------------------------- money.methods.create / edit

  /// The checks of `money.methods.create` (M-40 to M-43), and the account sealed.
  Future<MethodDraft> draftCreate(Map<String, Object?> args, Uint8List? key) async {
    final code = args["code"] is String ? (args["code"]! as String).trim().toLowerCase() : "";
    final country = _business.country;
    if (!Rails.offered(code, country, credit: Finance.credit)) throw const EngineFailure("unknown_rail");

    final options = Rails.options(country);
    final account = _account(Rails.sheet(code, options), {for (final field in Rails.fields) field: args[field]}, options);
    final currency = _currency(args["currency"], code);
    final fee = _fee(args["feeType"] ?? "none", args["fee"], currency);
    final id = newId();

    return MethodDraft._(id, code, {
      "label": _text(args["label"], "label"),
      "instructions": _text(args["instructions"], "instructions"),
      "institution": account["institution"],
      "sealed": await _seal(key, id, account),
      "currency": currency,
      ...fee,
      "position": _position(args["position"]) ?? Rails.kinds[code]!.$5,
    }, isNew: true);
  }

  /// The checks of `money.methods.edit`: a key left out keeps its value, `null` clears it. The
  /// account is checked as the merge of the change over what the row holds, so an edit can't
  /// clear a required field by leaving it out, nor be refused over one it didn't touch.
  Future<MethodDraft> draftEdit(Map<String, Object?> args, Uint8List? key) async {
    if (args.containsKey("code")) throw const EngineFailure(ErrorCodes.badRequest);

    final id = args["id"] is String ? args["id"]! as String : "";
    final row = _row(id);
    final code = row["code"] as String;
    final columns = <String, Object?>{};

    for (final field in _commonColumns) {
      if (args.containsKey(field)) columns[field] = _text(args[field], field);
    }

    if (Rails.fields.any(args.containsKey)) {
      final current = await _open(_need(key), row);
      final options = Rails.options(_business.country);
      final account = _account(Rails.sheet(code, options), {
        for (final field in Rails.fields) field: args.containsKey(field) ? args[field] : current[field],
      }, options);
      columns["institution"] = account["institution"];
      columns["sealed"] = await _seal(key, id, account);
    }

    if (args.containsKey("currency")) columns["currency"] = _currency(args["currency"], code);

    if (args.containsKey("feeType") || args.containsKey("fee")) {
      final type = args["feeType"] ?? row["fee_type"];
      final value = args.containsKey("fee")
        ? args["fee"]
        : (row["fee_type"] == "fixed" ? row["fee_fixed"] : row["fee_percent"]);
      final currency = columns.containsKey("currency") ? columns["currency"] : row["currency"];
      columns.addAll(_fee(type, type == "none" ? null : value, currency as String?));
    }

    if (args.containsKey("position")) {
      final position = _position(args["position"]);
      if (position != null) columns["position"] = position;
    }

    if (columns.isEmpty) throw const EngineFailure(ErrorCodes.badRequest);

    return MethodDraft._(id, code, columns, isNew: false);
  }

  /// Writes a [draft] (inside the op's write) and answers the account **without** its sealed
  /// fields: a write's answer is kept in clear under its `commandId` (`OpCall.write`); `list`
  /// reads them.
  Map<String, Object?> save(MethodDraft draft, {required String actor, String? device}) => _store.write((db) {
    final stamp = _clock.tick();

    if (draft.isNew) {
      final active = db.select("SELECT count(*) AS n FROM money_methods WHERE active = 1").first["n"] as int;
      if (active >= max) throw const EngineFailure("too_many_methods", {"max": max});

      final columns = {
        "id": draft.id,
        "code": draft.code,
        "method": Rails.kinds[draft.code]!.$2,
        ...draft.columns,
        "created": _now().toUtc().toIso8601String(),
        "created_hlc": stamp.pack(),
        "updated_hlc": stamp.pack(),
      };
      db.execute(
        "INSERT INTO money_methods (${columns.keys.join(", ")}) VALUES (${columns.keys.map((_) => "?").join(", ")})",
        columns.values.toList(),
      );
    } else {
      _row(draft.id);
      final columns = {...draft.columns, "updated_hlc": stamp.pack()};
      db.execute(
        "UPDATE money_methods SET ${columns.keys.map((column) => "$column = ?").join(", ")} WHERE id = ?",
        [...columns.values, draft.id],
      );
    }

    // What the oplog carries is never the sealed account.
    Oplog(db).append(
      hlc: stamp,
      entity: "money_method",
      entityId: draft.id,
      kind: draft.isNew ? "created" : "edited",
      payload: {
        for (final MapEntry(:key, :value) in draft.columns.entries)
          if (key != "sealed") key: value,
        if (draft.isNew) "code": draft.code,
      },
      actor: actor,
      device: device,
    );

    return _answer(_row(draft.id), const {}, Rails.options(_business.country))
      ..removeWhere((key, _) => _sealedColumns.contains(key));
  });

  // ---------------------------------------------------------------- money.methods.remove

  /// `money.methods.remove {id}` (M-44): soft, so the payments that named it keep its label.
  Map<String, Object?> remove(String id, {required String actor, String? device}) => _store.write((db) {
    final row = _row(id);
    final stamp = _clock.tick();

    db.execute("UPDATE money_methods SET active = 0, updated_hlc = ? WHERE id = ?", [stamp.pack(), id]);
    Oplog(db).append(hlc: stamp, entity: "money_method", entityId: id, kind: "removed", actor: actor, device: device);
    AuditLog(db, now: _now).append(AuditKinds.methodRemoved, actor: actor, device: device, data: {
      "method": id,
      "code": row["code"],
      "label": row["label"],
    });

    return const <String, Object?>{};
  });

  // ---------------------------------------------------------------- internals

  Row _row(String id) {
    final row = _db.select("SELECT * FROM money_methods WHERE id = ? AND active = 1", [id]).firstOrNull;
    if (row == null) throw const EngineFailure(ErrorCodes.notFound);

    return row;
  }

  static Uint8List _need(Uint8List? key) => key ?? (throw const EngineFailure("sealed_locked"));

  static String _context(String id) => "lyra/sealed/payments/money_method/$id";

  /// The account's sealed fields, or null when it has none (cash), which needs no key.
  static Future<Uint8List?> _seal(Uint8List? key, String id, Map<String, Object?> account) async {
    final clear = {for (final field in _sealedColumns) if (account[field] != null) field: account[field]};
    if (clear.isEmpty) return null;

    return SealedKeys.sealJson(_need(key), clear, context: _context(id));
  }

  static Future<Map<String, Object?>> _open(Uint8List key, Row row) async {
    final sealed = row["sealed"] as Uint8List?;
    final clear = sealed == null
      ? const <String, Object?>{}
      : await SealedKeys.openJson(key, sealed, context: _context(row["id"] as String));

    return {...clear, "institution": row["institution"]};
  }

  Map<String, Object?> _answer(Row row, Map<String, Object?> account, Map<String, List<Map<String, String>>> options) {
    final code = row["code"] as String;
    final method = row["method"] as String;
    final language = _business.language;
    final rail = Rails.kinds.containsKey(code) ? Rails.row(code, language) : null;
    final (reference, change, _, _) = Settlements.kinds[method] ?? (false, false, false, const <String, String>{});
    final institution = row["institution"] as String?;
    final picked = Rails.sheet(code, options).where((field) => field.field == "institution" && field.type == "select");
    final institutionName = institution == null || picked.isEmpty
      ? null
      : options[picked.first.options]?.where((option) => option["code"] == institution).firstOrNull?["name"];

    return {
      "id": row["id"],
      "code": code,
      "name": rail?["name"] ?? code,
      "label": row["label"],
      "method": method,
      "methodName": Settlements.name(method, language),
      "holder": account["holder"],
      "document": account["document"],
      "institution": institution,
      "institutionName": institutionName,
      "account": account["account"],
      "currency": row["currency"],
      "fee": switch (row["fee_type"]) {
        "fixed" => {"type": "fixed", "value": num.parse(row["fee_fixed"] as String)},
        "percent" => {"type": "percent", "value": row["fee_percent"]},
        _ => {"type": "none", "value": 0},
      },
      "instructions": row["instructions"],
      "icon": null,
      "reference": reference,
      "change": change,
      "position": row["position"],
    };
  }

  /// The four columns read against [sheet] (M-41): what the sheet doesn't name is null, a
  /// `select` stores the option's code, a `document` its type and number joined, and a field with a
  /// `format` is stored spaced by it.
  static Map<String, Object?> _account(
    List<RailField> sheet,
    Map<String, Object?> values,
    Map<String, List<Map<String, String>>> options,
  ) {
    final account = <String, Object?>{for (final field in Rails.fields) field: null};

    for (final entry in sheet) {
      final value = _text(values[entry.field], entry.field);

      if (value == null) {
        if (entry.required) throw EngineFailure(ErrorCodes.required, {"field": entry.field});
        continue;
      }

      if (entry.type == "select") {
        final option = _option(options[entry.options], value);
        if (option == null) throw EngineFailure("invalid_option", {"field": entry.field});

        account[entry.field] = option;
        continue;
      }

      if (entry.type == "document" && entry.options != null) {
        final (type, number) = Rails.document(value);
        final option = type == null ? null : _option(options[entry.options], type);
        if (option == null || number.isEmpty) throw EngineFailure("invalid_option", {"field": entry.field});

        account[entry.field] = "$option${Rails.documentSeparator}$number";
        continue;
      }

      account[entry.field] = entry.format == null ? value : _text(Rails.format(entry.format, value), entry.field);
    }

    return account;
  }

  static String? _option(List<Map<String, String>>? list, String code) {
    final wanted = code.trim().toLowerCase();

    return list?.where((option) => option["code"]!.toLowerCase() == wanted).firstOrNull?["code"];
  }

  /// M-42: a rail that moves one currency stores it whatever is sent; else the main currency or an
  /// active exchange one. Null is the main currency.
  String? _currency(Object? raw, String code) {
    final fixed = Rails.kinds[code]!.$4;
    if (fixed != null) return fixed;
    if (raw == null || raw is String && raw.trim().isEmpty) return null;
    if (raw is! String) throw const EngineFailure("unknown_currency");

    final currency = raw.trim().toUpperCase();
    if (currency == _business.currency) return null;

    final active = _db.select("SELECT 1 FROM money_currencies WHERE currency = ? AND active = 1", [currency]);
    if (active.isEmpty) throw const EngineFailure("unknown_currency");

    return currency;
  }

  /// M-43: `none`; `fixed`, an amount of the account's [currency] (null: the main one) above 0 with
  /// at most its decimals; or `percent`, above 0 and below 100. Both kept as decimal text.
  ///
  /// The fixed amount travels as a number, like a rate, and not in minor units: it is in the
  /// account's currency, which an edit's body doesn't always name, while the engine knows it.
  Map<String, Object?> _fee(Object? type, Object? value, String? currency) {
    switch (type) {
      case "none":
        return {"fee_type": "none", "fee_fixed": null, "fee_percent": null};
      case "fixed":
        final amount = _amount(value, _decimalsOf(currency ?? _business.currency));
        if (amount == null) throw const EngineFailure("invalid_fee");

        return {"fee_type": "fixed", "fee_fixed": amount, "fee_percent": null};
      case "percent":
        final percent = Money.percent(value);
        if (percent == null || percent == "0" || percent == "100") throw const EngineFailure("invalid_fee");

        return {"fee_type": "percent", "fee_fixed": null, "fee_percent": percent};
      default:
        throw const EngineFailure("invalid_fee");
    }
  }

  /// [value] as canonical decimal text (`1.5`), or null when it isn't a number above 0 with at
  /// most [decimals] decimals.
  static String? _amount(Object? value, int decimals) {
    final text = switch (value) {
      final int number => "$number",
      final double number when number.isFinite => "$number",
      final String text => text.trim(),
      _ => null,
    };
    final match = text == null ? null : RegExp(r"^(\d{1,15})(?:\.(\d+))?$").firstMatch(text);
    if (match == null) return null;

    final whole = match[1]!.replaceFirst(RegExp(r"^0+(?=\d)"), "");
    final fraction = (match[2] ?? "").replaceFirst(RegExp(r"0+$"), "");
    if (fraction.length > decimals || (int.parse(whole) == 0 && fraction.isEmpty)) return null;

    return fraction.isEmpty ? whole : "$whole.$fraction";
  }

  static int _decimalsOf(String currency) =>
    Catalogs.currencyRows.where((row) => row["code"] == currency).firstOrNull?["decimals"] as int? ?? 2;

  /// A position from 0 to 65535, or null (left where it is): a preference isn't worth a refusal.
  static int? _position(Object? raw) => raw is int && raw >= 0 && raw <= 65535 ? raw : null;

  /// A text column: control characters as spaces, spaces collapsed, cut to its ceiling; null when
  /// nothing is left. A value that isn't text is refused.
  static String? _text(Object? raw, String field) {
    if (raw == null) return null;
    if (raw is! String) throw EngineFailure(ErrorCodes.invalidField, {"field": field});

    final text = raw.replaceAll(RegExp(r"[\x00-\x1F\x7F]"), " ").replaceAll(RegExp(r"\s+"), " ").trim();
    if (text.isEmpty) return null;

    final max = limits[field] ?? 120;

    return text.length > max ? text.substring(0, max) : text;
  }
}
