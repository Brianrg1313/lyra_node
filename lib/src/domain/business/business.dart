import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../audit/audit_log.dart';
import '../../failure.dart';
import '../../ids.dart';
import '../../net/events.dart';
import '../../net/files.dart';
import '../../oplog/hlc.dart';
import '../../oplog/oplog.dart';
import '../../storage/store.dart';
import 'zones.dart';

/// What setup creates the company with (`business.md` B-1).
final class CompanyDraft {
  const CompanyDraft({
    required this.name,
    required this.country,
    required this.currency,
    required this.language,
    this.timezone,
  });

  factory CompanyDraft.fromJson(Map<String, Object?> json) => CompanyDraft(
    name: json["name"] as String? ?? "",
    country: json["country"] as String? ?? "",
    currency: json["currency"] as String? ?? "",
    language: json["language"] as String? ?? "",
    timezone: json["timezone"] as String?,
  );

  final String name;
  final String country;
  final String currency;
  final String language;
  final String? timezone;

  /// Throws the refusal for the first field that is wrong, before anything is written.
  void check() {
    Business._text("name", name, required: true);
    Business._country(country);
    if (!Catalogs.hasCurrency(currency.trim().toUpperCase())) {
      throw const EngineFailure(ErrorCodes.invalidField, {"field": "currency"});
    }
    Business._language(language);
    if (timezone != null && timezone!.trim().isNotEmpty) Business._timezone(timezone!);
  }
}

/// The master's one company and its one site (`business.md`, plan D6).
///
/// Every write joins the running `Store.write` of its op (`OpCall.write`), so the change, its
/// oplog entry and its `business/changed` event commit together.
final class Business {
  Business(this._store, this._clock, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Store _store;
  final HlcClock _clock;
  final DateTime Function() _now;

  Database get _db => _store.db;

  /// Who receives `business/changed`: whoever can read the profile.
  static const viewPermission = "business.view";

  /// Longest text each field takes.
  static const _limits = {
    "name": 120, "legalName": 160, "nickname": 64, "caption": 280, "taxId": 64, "phone": 32,
    "website": 256, "address": 256, "landmark": 160, "city": 120, "region": 120, "postalCode": 16,
  };

  static const _columns = {
    "name": "name", "legalName": "legal_name", "nickname": "nickname", "caption": "caption",
    "activity": "activity", "taxId": "tax_id", "country": "country", "language": "language",
    "phone": "phone", "website": "website", "incorporationDate": "incorporation_date", "timezone": "timezone",
    "address": "address", "landmark": "landmark", "city": "city", "region": "region", "postalCode": "postal_code",
  };

  /// Creates the company and its site at setup (B-1). Runs once: a second call hits the
  /// single-row constraint.
  static void create(Database db, CompanyDraft draft, {required HlcClock clock, required DateTime now, String? actor}) {
    draft.check();

    final stamp = clock.tick();
    final id = newId();
    final name = draft.name.trim();
    final timezone = draft.timezone?.trim();

    db.execute(
      "INSERT INTO company (id, name, country, currency, language, timezone, created, created_hlc, updated_hlc) "
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [id, name, draft.country.trim().toUpperCase(), draft.currency.trim().toUpperCase(),
        draft.language.trim().toLowerCase(), timezone == null || timezone.isEmpty ? null : timezone,
        now.toUtc().toIso8601String(), stamp.pack(), stamp.pack()],
    );
    db.execute(
      "INSERT INTO site (id, name, created_hlc, updated_hlc) VALUES (?, ?, ?, ?)",
      [newId(), name, stamp.pack(), stamp.pack()],
    );
    Oplog(db).append(hlc: stamp, entity: "company", entityId: id, kind: "created", payload: {
      "name": name,
      "country": draft.country,
      "currency": draft.currency,
      "language": draft.language,
    }, actor: actor);
    AuditLog(db, now: () => now).append(AuditKinds.companyCreated, actor: actor, data: {"company": id, "name": name});
  }

  bool get exists => _db.select("SELECT 1 FROM company WHERE deleted = 0").isNotEmpty;

  Row get _company {
    final rows = _db.select("SELECT * FROM company WHERE deleted = 0");
    if (rows.isEmpty) throw const EngineFailure(ErrorCodes.notFound);

    return rows.first;
  }

  Row get _site {
    final rows = _db.select("SELECT * FROM site WHERE deleted = 0");
    if (rows.isEmpty) throw const EngineFailure(ErrorCodes.notFound);

    return rows.first;
  }

  String get id => _company["id"] as String;

  /// The company's zone, or its country's default one (B-9).
  String get timezone {
    final row = _company;

    return row["timezone"] as String? ?? Catalogs.country(row["country"] as String)?["timezone"] as String? ?? "UTC";
  }

  /// The company's language (`es`, `en`, …): what catalogue texts are named in (B-22).
  String get language => _company["language"] as String;

  /// The company's main currency (ISO 4217): what POS money is counted in.
  String get currency => _company["currency"] as String;

  /// How many minor digits [currency] has (`CurrencyModel.decimals`).
  int get decimals =>
    Catalogs.currencyRows.where((row) => row["code"] == currency).firstOrNull?["decimals"] as int? ?? 2;

  /// `business.profile`. [owner]: whether the reader holds `*` (the app's "owner" badge).
  Map<String, Object?> profile({required bool owner}) {
    final row = _company;

    return {
      "id": row["id"],
      "name": row["name"],
      "legalName": row["legal_name"],
      "nickname": row["nickname"],
      "caption": row["caption"],
      "logo": row["logo"],
      "activity": row["activity"],
      "taxId": row["tax_id"],
      "country": row["country"],
      "language": row["language"],
      "currency": row["currency"],
      "phone": row["phone"],
      "website": row["website"],
      "incorporationDate": row["incorporation_date"],
      "timezone": row["timezone"],
      "verification": "untrusted",
      "emails": const <Object?>[],
      "created": row["created"],
      "owner": owner,
    };
  }

  /// The company as the bootstrap lists it (`session.md` S-30).
  Map<String, Object?> summary() {
    final row = _company;

    return {
      "id": row["id"],
      "name": row["name"],
      "caption": row["caption"],
      "logo": row["logo"],
      "activity": row["activity"],
      "profile": row["nickname"],
      "currency": row["currency"],
    };
  }

  /// `business.edit {key: value}` (B-2): one key; `""` or null clears an optional field.
  Map<String, Object?> edit(Map<String, Object?> args, {required bool owner, String? actor, String? device}) {
    if (args.length != 1) throw const EngineFailure(ErrorCodes.badRequest);

    final key = args.keys.single;
    final raw = args[key];

    if (!BusinessFields.editable.contains(key)) throw EngineFailure(ErrorCodes.invalidField, {"field": key});
    if (raw != null && raw is! String) throw EngineFailure(ErrorCodes.invalidField, {"field": key});

    final value = _profileValue(key, raw as String?);

    _store.write((db) {
      final stamp = _clock.tick();
      final row = _company;

      db.execute("UPDATE company SET ${_columns[key]} = ?, updated_hlc = ? WHERE id = ?", [value, stamp.pack(), row["id"]]);
      _changed(db, stamp, row["id"] as String, {key: value}, actor: actor, device: device);
    });

    return profile(owner: owner);
  }

  /// `business.setLogo {fileId | null}` (B-8): the upload becomes the logo, readable by whoever
  /// reads the profile; the previous one is let go (the orphan sweep deletes it).
  Map<String, Object?> setLogo(String? fileId, FileStore files, {required bool owner, required String actor, String? device}) {
    _store.write((db) {
      final stamp = _clock.tick();
      final row = _company;
      final previous = row["logo"] as String?;

      if (fileId == previous) return;
      if (fileId != null) files.claim(fileId, FilePurpose.logo, permission: viewPermission, uploader: actor);
      if (previous != null) files.release(previous);

      db.execute("UPDATE company SET logo = ?, updated_hlc = ? WHERE id = ?", [fileId, stamp.pack(), row["id"]]);
      _changed(db, stamp, row["id"] as String, {"logo": fileId}, actor: actor, device: device);
    });

    return profile(owner: owner);
  }

  /// `business.site.get`: the one site, with the company's country (B-12). `maps` is left to
  /// the reader, which derives it from the point.
  Map<String, Object?> site() {
    final row = _site;
    final latitude = row["latitude"] as int?;
    final longitude = row["longitude"] as int?;

    return {
      "id": row["id"],
      "main": true,
      "name": row["name"],
      "legalName": row["legal_name"],
      "taxId": row["tax_id"],
      "phone": row["phone"],
      "address": row["address"],
      "landmark": row["landmark"],
      "city": row["city"],
      "region": row["region"],
      "postalCode": row["postal_code"],
      "country": _company["country"],
      "latitude": latitude == null ? null : latitude / 1e6,
      "longitude": longitude == null ? null : longitude / 1e6,
      "storefront": row["storefront"] == 1,
      "online": row["online"] == 1,
    };
  }

  /// `business.site.edit {changed keys}` (B-10, B-11, B-12): only what changed; null clears.
  Map<String, Object?> editSite(Map<String, Object?> changes, {String? actor, String? device}) {
    final columns = <String, Object?>{};
    final unknown = changes.keys.where((key) => !BusinessFields.site.contains(key));
    if (unknown.isNotEmpty) throw EngineFailure(ErrorCodes.invalidField, {"field": unknown.first});

    for (final entry in changes.entries) {
      final key = entry.key;
      final value = entry.value;

      switch (key) {
        case "latitude" || "longitude" || "country":
          continue;
        case "storefront" || "online":
          if (value is! bool) throw EngineFailure(ErrorCodes.invalidField, {"field": key});
          columns[key] = value ? 1 : 0;
        default:
          if (value != null && value is! String) throw EngineFailure(ErrorCodes.invalidField, {"field": key});
          columns[_columns[key]!] = key == "phone" ? _phone(value as String?) : _text(key, value as String?, required: key == "name");
      }
    }

    final point = _point(changes);
    final country = changes.containsKey("country") ? _profileValue("country", changes["country"] as String?) : null;

    _store.write((db) {
      final stamp = _clock.tick();
      final row = _site;

      if (point != null) {
        columns["latitude"] = point.$1;
        columns["longitude"] = point.$2;
      }

      if (columns.isNotEmpty) {
        db.execute(
          "UPDATE site SET ${columns.keys.map((column) => "$column = ?").join(", ")}, updated_hlc = ? WHERE id = ?",
          [...columns.values, stamp.pack(), row["id"]],
        );
        Oplog(db).append(hlc: stamp, entity: "site", entityId: row["id"] as String, kind: "edited",
          payload: {for (final key in changes.keys) if (key != "country") key: changes[key]}, actor: actor, device: device);
        EventLog.append(db, Events.businessChanged, {"keys": ["site"]}, at: _now(), permission: viewPermission);
      }

      if (country != null) {
        final company = _company["id"] as String;
        db.execute("UPDATE company SET country = ?, updated_hlc = ? WHERE id = ?", [country, stamp.pack(), company]);
        _changed(db, stamp, company, {"country": country}, actor: actor, device: device);
      }
    });

    return site();
  }

  void _changed(Database db, Hlc stamp, String id, Map<String, Object?> change, {String? actor, String? device}) {
    Oplog(db).append(hlc: stamp, entity: "company", entityId: id, kind: "edited", payload: change, actor: actor, device: device);
    EventLog.append(db, Events.businessChanged, {"keys": change.keys.toList()}, at: _now(), permission: viewPermission);
  }

  /// A half point is refused, and each half is range-checked (B-11). Null when the edit doesn't
  /// touch the point; `(null, null)` clears it.
  static (int?, int?)? _point(Map<String, Object?> changes) {
    final hasLatitude = changes.containsKey("latitude");
    final hasLongitude = changes.containsKey("longitude");
    if (!hasLatitude && !hasLongitude) return null;

    final latitude = changes["latitude"];
    final longitude = changes["longitude"];

    if (hasLatitude != hasLongitude || (latitude == null) != (longitude == null)) {
      throw const EngineFailure("invalid_point");
    }
    if (latitude == null) return (null, null);

    int micro(Object? value, String field, double limit) {
      final number = value is num ? value.toDouble() : value is String ? double.tryParse(value) : null;
      if (number == null || !number.isFinite || number.abs() > limit) throw const EngineFailure("invalid_point");

      return (number * 1e6).round();
    }

    return (micro(latitude, "latitude", 90), micro(longitude, "longitude", 180));
  }

  /// What [key] stores for [raw] (a trimmed text, a code, or null to clear).
  static Object? _profileValue(String key, String? raw) => switch (key) {
    "name" => _text(key, raw, required: true),
    "country" => _country(raw ?? ""),
    "language" => _language(raw ?? ""),
    "activity" => _activity(raw),
    "incorporationDate" => _day(raw),
    "timezone" => raw == null || raw.trim().isEmpty ? null : _timezone(raw),
    "phone" => _phone(raw),
    "website" => _website(raw),
    _ => _text(key, raw),
  };

  static String? _text(String key, String? raw, {bool required = false}) {
    final value = raw?.trim() ?? "";

    if (value.isEmpty) {
      if (required) throw EngineFailure(ErrorCodes.required, {"field": key});
      return null;
    }
    if (value.length > (_limits[key] ?? 256)) throw EngineFailure(ErrorCodes.invalidField, {"field": key});

    return value;
  }

  static String _country(String raw) {
    final code = raw.trim().toUpperCase();

    if (code.isEmpty) throw const EngineFailure(ErrorCodes.required, {"field": "country"});
    if (Catalogs.country(code) == null) throw const EngineFailure(ErrorCodes.invalidField, {"field": "country"});

    return code;
  }

  static String _language(String raw) {
    final code = raw.trim().toLowerCase();

    if (code.isEmpty) throw const EngineFailure(ErrorCodes.required, {"field": "language"});
    if (!Catalogs.languages.contains(code)) throw const EngineFailure(ErrorCodes.invalidField, {"field": "language"});

    return code;
  }

  static String? _activity(String? raw) {
    final code = raw?.trim().toUpperCase() ?? "";
    if (code.isEmpty) return null;
    if (!Catalogs.activities.contains(code)) throw const EngineFailure(ErrorCodes.invalidField, {"field": "activity"});

    return code;
  }

  /// A calendar day, `YYYY-MM-DD`, that exists (README, time).
  static String? _day(String? raw) {
    final value = raw?.trim() ?? "";
    if (value.isEmpty) return null;

    final match = RegExp(r"^(\d{4})-(\d{2})-(\d{2})$").firstMatch(value);
    final parsed = match == null ? null : DateTime.utc(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));

    if (parsed == null || parsed.month != int.parse(match![2]!) || parsed.day != int.parse(match[3]!)) {
      throw const EngineFailure(ErrorCodes.invalidField, {"field": "incorporationDate"});
    }

    return value;
  }

  /// A zone of the IANA database the engine carries (B-9, `Zones`).
  static String _timezone(String raw) {
    final value = raw.trim();

    if (!Zones.known(value)) throw const EngineFailure("invalid_timezone");

    return value;
  }

  static String? _phone(String? raw) {
    final value = raw?.trim() ?? "";
    if (value.isEmpty) return null;
    if (!RegExp(r"^\+?[0-9 ()\-]{4,31}$").hasMatch(value)) throw const EngineFailure(ErrorCodes.invalidField, {"field": "phone"});

    return value;
  }

  static String? _website(String? raw) {
    final value = raw?.trim() ?? "";
    if (value.isEmpty) return null;
    if (value.length > 256 || value.contains(RegExp(r"\s"))) {
      throw const EngineFailure(ErrorCodes.invalidField, {"field": "website"});
    }

    return value;
  }
}
