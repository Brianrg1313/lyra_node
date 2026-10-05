import 'dart:convert';

import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../failure.dart';
import '../../ids.dart';
import '../../oplog/hlc.dart';
import '../../oplog/oplog.dart';
import '../../storage/store.dart';
import '../business/business.dart';
import 'carriers.dart';

/// Whether, how and where the company delivers (`deliveries.md`): the settings, the options and
/// the areas drawn on the map. Kept on the master for `hybrid` (the section is hidden in `local`)
/// and synced with the cloud, whose rules these are, so a value accepted here is one the cloud
/// stores as sent.
///
/// Money is in minor units of the company's currency, distances in metres, times in minutes and a
/// point in degrees on the wire (millionths in the tables).
final class Deliveries {
  Deliveries(this._store, this._clock, this._business, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// D-11, and the cloud's ceiling on options: a list a customer is read has to be short.
  static const maxOptions = 20;
  static const maxAreas = 20;

  /// Zones per option and the length of one: a neighbourhood or a town, not an address.
  static const maxZones = 100;
  static const zoneLength = 80;

  /// Points of an outline (D-10).
  static const minPoints = 3;
  static const maxPoints = 250;

  /// Kilometres with two decimals in the cloud: 10 m to 1000 km.
  static const minRadius = 10;
  static const maxRadius = 1000000;

  /// Minutes, up to thirty days.
  static const maxEta = 43200;

  static const modes = ["own", "platform", "courier"];
  static const coverages = ["local", "national", "international"];
  static const kinds = ["radius", "polygon"];

  /// The reach an option starts with (D-3): riders and apps work a city, a parcel carrier the country.
  static const _reach = {"own": "local", "platform": "local", "courier": "national"};

  /// The cloud's text rules (`LABEL`, `NOTES`, `NAME`): longer, or with a character outside its
  /// set, is refused there, so it is here.
  static const _labelLength = 64;
  static const _notesLength = 255;
  static const _nameLength = 64;
  static final _labelChars = RegExp(r"^[A-Za-z0-9 .,&'()/+üÜñáéíóúÑÁÉÍÓÚ-]+$");
  static final _notesChars = RegExp("^[A-Za-z0-9 .,;:!¡?¿'\"()/&%@#+=*_\$€°ºªüÜñáéíóúÑÁÉÍÓÚàèìòùâêîôûçÀÈÌÒÙÂÊÎÔÛÇ-]+\$");

  /// The option's edge field → its column.
  static const optionColumns = {
    "mode": "mode", "provider": "provider", "label": "label", "coverage": "coverage", "radius": "radius",
    "zones": "zones", "fee": "fee", "freeFrom": "free_from", "etaMin": "eta_min", "etaMax": "eta_max",
    "notes": "notes", "position": "position",
  };

  /// The area's edge field → its column.
  static const areaColumns = {
    "name": "name", "kind": "kind", "latitude": "latitude", "longitude": "longitude", "radius": "radius",
    "polygon": "polygon", "fee": "fee", "minimum": "minimum", "active": "active", "position": "position",
  };

  /// The settings' edge fields (on the company) → their columns.
  static const settingColumns = {
    "delivers": "delivers", "pickup": "pickup", "meetingPoint": "meeting_point", "deliveryNotes": "delivery_notes",
  };

  final Store _store;
  final HlcClock _clock;
  final Business _business;
  final DateTime Function() _now;

  Database get _db => _store.db;

  // ---------------------------------------------------------------- delivery.get / set

  /// `delivery.get`: a company that lists a way to deliver has said yes by doing so, which is
  /// answered without being written back.
  Map<String, Object?> settings() {
    final company = _db.select("SELECT delivers, pickup, meeting_point, delivery_notes FROM company").first;
    final options = [for (final row in _live("delivery_options")) _option(row)];
    final delivers = company["delivers"] as int?;

    return {
      "delivers": delivers == null ? (options.isEmpty ? null : true) : delivers == 1,
      "pickup": company["pickup"] == null ? null : company["pickup"] == 1,
      "notes": company["delivery_notes"],
      "meeting": company["meeting_point"] == 1,
      "currency": _business.currency,
      "options": options,
    };
  }

  /// `delivery.set {delivers?, pickup?, meeting?, notes?}` (D-1): `null` puts a flag back to "has
  /// not said" and clears the notes; `meeting` has no third state.
  Map<String, Object?> set(Map<String, Object?> args, {String? actor, String? device}) {
    const keys = {"delivers": "delivers", "pickup": "pickup", "meeting": "meetingPoint", "notes": "deliveryNotes"};
    if (args.isEmpty || args.keys.any((key) => !keys.containsKey(key))) throw const EngineFailure(ErrorCodes.badRequest);

    final changes = <String, Object?>{};
    for (final MapEntry(:key, :value) in args.entries) {
      changes[keys[key]!] = switch (key) {
        "notes" => _text(value, "notes", max: _notesLength, chars: _notesChars),
        "meeting" => value is bool ? value : throw const EngineFailure("invalid_delivery_flag"),
        _ => value == null || value is bool ? value : throw const EngineFailure("invalid_delivery_flag"),
      };
    }

    _store.write((db) {
      final stamp = _clock.tick();
      final id = _business.id;

      db.execute(
        "UPDATE company SET ${[for (final field in changes.keys) "${settingColumns[field]} = ?", "updated_hlc = ?"].join(", ")} WHERE id = ?",
        [for (final value in changes.values) value is bool ? (value ? 1 : 0) : value, stamp.pack(), id],
      );
      Oplog(db).append(hlc: stamp, entity: "company", entityId: id, kind: "edited", payload: changes, actor: actor, device: device);
    });

    return settings();
  }

  /// `delivery.providers`: what an option can be, and the carriers of the company's country.
  Map<String, Object?> providers() {
    final country = _business.country;

    return {"country": country, "modes": modes, "coverages": coverages, "providers": Carriers.offered(country)};
  }

  // ---------------------------------------------------------------- delivery.options.*

  /// `delivery.options.create`: a key left out is the default (the mode's reach, no price).
  Map<String, Object?> createOption(Map<String, Object?> args, {String? actor, String? device}) {
    final row = _composeOption(const {
      "mode": null, "provider": null, "label": null, "coverage": null, "radius": null, "zones": <Object?>[],
      "fee": null, "freeFrom": null, "etaMin": null, "etaMax": null, "notes": null, "position": 100,
    }, args, creating: true);

    _store.write((db) {
      final count = db.select("SELECT count(*) AS n FROM delivery_options WHERE deleted = 0").first["n"] as int;
      if (count >= maxOptions) throw const EngineFailure("delivery_options_limit", {"max": maxOptions});

      final stamp = _clock.tick();
      final id = newId();
      _insert(db, "delivery_options", optionColumns, id, row, stamp);
      Oplog(db).append(hlc: stamp, entity: "delivery_option", entityId: id, kind: "created", payload: row, actor: actor, device: device);
    });

    return settings();
  }

  /// `delivery.options.edit {id, …}`: a key left out keeps its value, `null` clears it, and the
  /// result is checked whole (D-6).
  Map<String, Object?> editOption(Map<String, Object?> args, {String? actor, String? device}) {
    final id = args["id"];
    final current = _find("delivery_options", id);
    final before = _optionFields(current);
    final row = _composeOption(before, args);

    _store.write((db) {
      _find("delivery_options", id);
      _update(db, "delivery_options", "delivery_option", optionColumns, id as String, before, row, actor: actor, device: device);
    });

    return settings();
  }

  /// `delivery.options.remove {id}`.
  Map<String, Object?> removeOption(Object? id, {String? actor, String? device}) {
    _remove("delivery_options", "delivery_option", id, actor: actor, device: device);

    return settings();
  }

  // ---------------------------------------------------------------- delivery.areas.*

  /// `delivery.areas.list`.
  Map<String, Object?> areas() => {
    "currency": _business.currency,
    "areas": [for (final row in _live("delivery_areas")) _area(row)],
  };

  /// `delivery.areas.create` (D-10, D-11).
  Map<String, Object?> createArea(Map<String, Object?> args, {String? actor, String? device}) {
    if (!args.containsKey("name")) throw const EngineFailure(ErrorCodes.required, {"field": "name"});

    final row = _composeArea(const {
      "name": null, "kind": null, "latitude": null, "longitude": null, "radius": null, "polygon": <Object?>[],
      "fee": null, "minimum": null, "active": true, "position": 100,
    }, args);

    _store.write((db) {
      final count = db.select("SELECT count(*) AS n FROM delivery_areas WHERE deleted = 0").first["n"] as int;
      if (count >= maxAreas) throw const EngineFailure("delivery_areas_limit", {"max": maxAreas});

      final stamp = _clock.tick();
      final id = newId();
      _insert(db, "delivery_areas", areaColumns, id, row, stamp);
      Oplog(db).append(hlc: stamp, entity: "delivery_area", entityId: id, kind: "created", payload: row, actor: actor, device: device);
    });

    return areas();
  }

  /// `delivery.areas.edit {id, …}`: as an option's, and `{id, active}` alone pauses or resumes it
  /// (D-13).
  Map<String, Object?> editArea(Map<String, Object?> args, {String? actor, String? device}) {
    final id = args["id"];
    final before = _areaFields(_find("delivery_areas", id));
    final row = _composeArea(before, args);

    _store.write((db) {
      _find("delivery_areas", id);
      _update(db, "delivery_areas", "delivery_area", areaColumns, id as String, before, row, actor: actor, device: device);
    });

    return areas();
  }

  /// `delivery.areas.remove {id}`: nothing refers to an area (D-13).
  Map<String, Object?> removeArea(Object? id, {String? actor, String? device}) {
    _remove("delivery_areas", "delivery_area", id, actor: actor, device: device);

    return areas();
  }

  // ---------------------------------------------------------------- rules

  /// An option's write over [current] (edge fields), checked whole as the cloud does (D-2 to D-5).
  Map<String, Object?> _composeOption(Map<String, Object?> current, Map<String, Object?> args, {bool creating = false}) {
    final row = {...current};
    final country = _business.country;

    String? mode;
    if (args.containsKey("mode")) {
      mode = _member(args["mode"], modes);
      // Blank is refused too: an order is always carried by somebody.
      if (mode == null) throw const EngineFailure("invalid_delivery_mode");
    }

    if (args.containsKey("provider")) {
      final raw = args["provider"];
      if (raw != null && raw is! String) throw const EngineFailure("invalid_delivery_provider");

      final code = (raw as String?)?.trim().toLowerCase() ?? "";
      if (code.isEmpty) {
        row["provider"] = null;
        if (mode != null) row["mode"] = mode;
      } else {
        final carrier = Carriers.pick(code, country) ?? (throw const EngineFailure("invalid_delivery_provider"));
        if (mode != null && mode != carrier.$2) throw const EngineFailure("delivery_provider_mismatch");

        row["provider"] = carrier.$1;
        row["mode"] = carrier.$2;
      }
    } else if (mode != null) {
      // Another kind of carrier is another carrier: the one the row named no longer applies.
      if (mode != row["mode"]) row["provider"] = null;
      row["mode"] = mode;
    }

    if (row["mode"] == null) throw const EngineFailure("invalid_delivery_mode");
    if (row["mode"] == "own") row["provider"] = null;

    if (args.containsKey("label")) row["label"] = _text(args["label"], "label", max: _labelLength, chars: _labelChars);
    if (args.containsKey("notes")) row["notes"] = _text(args["notes"], "notes", max: _notesLength, chars: _notesChars);

    // "We send it by parcel" is no answer to "with which company?".
    if (row["mode"] != "own" && row["provider"] == null && row["label"] == null) {
      throw const EngineFailure("delivery_provider_required");
    }

    if (args.containsKey("coverage")) {
      final raw = args["coverage"];
      final coverage = _member(raw, coverages);
      if (coverage == null && raw != null && !(raw is String && raw.trim().isEmpty)) {
        throw const EngineFailure("invalid_delivery_coverage");
      }

      row["coverage"] = coverage ?? _reach[row["mode"]];
    } else if (creating || row["coverage"] == null) {
      row["coverage"] = _reach[row["mode"]];
    }

    if (args.containsKey("radius")) row["radius"] = _radius(args["radius"]);
    if (args.containsKey("fee")) row["fee"] = _amount(args["fee"]);
    if (args.containsKey("freeFrom")) row["freeFrom"] = _amount(args["freeFrom"]);
    if (args.containsKey("etaMin")) row["etaMin"] = _eta(args["etaMin"]);
    if (args.containsKey("etaMax")) row["etaMax"] = _eta(args["etaMax"]);
    if (args.containsKey("position")) row["position"] = _position(args["position"]);
    if (args.containsKey("zones")) row["zones"] = _zones(args["zones"]);

    // D-4: a reach that isn't local keeps no zones and no radius.
    if (row["coverage"] != "local") {
      row["radius"] = null;
      row["zones"] = const <Object?>[];
    }

    final (etaMin, etaMax) = (row["etaMin"] as int?, row["etaMax"] as int?);
    if (etaMin != null && etaMax != null && etaMin > etaMax) throw const EngineFailure("invalid_delivery_eta");

    return row;
  }

  /// An area's write over [current], checked whole (D-10): each kind keeps only its own shape.
  Map<String, Object?> _composeArea(Map<String, Object?> current, Map<String, Object?> args) {
    final row = {...current};

    if (args.containsKey("name")) {
      row["name"] = _text(args["name"], "name", max: _nameLength) ??
        (throw const EngineFailure(ErrorCodes.required, {"field": "name"}));
    }

    if (args.containsKey("kind")) {
      row["kind"] = _member(args["kind"], kinds) ?? (throw const EngineFailure("invalid_delivery_area_kind"));
    }
    if (row["kind"] == null) throw const EngineFailure("invalid_delivery_area_kind");

    if (args.containsKey("latitude") || args.containsKey("longitude")) {
      final latitude = _coordinate(args.containsKey("latitude") ? args["latitude"] : _degrees(row["latitude"]), 90);
      final longitude = _coordinate(args.containsKey("longitude") ? args["longitude"] : _degrees(row["longitude"]), 180);
      if (latitude == null || longitude == null) throw const EngineFailure("invalid_delivery_area_center");

      row["latitude"] = latitude;
      row["longitude"] = longitude;
    }

    if (args.containsKey("polygon")) row["polygon"] = _ring(args["polygon"]);
    if (args.containsKey("radius")) row["radius"] = _radius(args["radius"]);
    if (args.containsKey("fee")) row["fee"] = _amount(args["fee"]);
    if (args.containsKey("minimum")) row["minimum"] = _amount(args["minimum"]);
    if (args.containsKey("position")) row["position"] = _position(args["position"]);

    if (args.containsKey("active")) {
      final active = args["active"];
      // Blank is "not paused": an area was drawn to be delivered to.
      if (active != null && active is! bool) throw const EngineFailure("invalid_delivery_flag");
      row["active"] = active != false;
    }

    if (row["kind"] == "radius") {
      row["polygon"] = const <Object?>[];
      if (row["latitude"] == null || row["longitude"] == null) throw const EngineFailure("invalid_delivery_area_center");
      if (row["radius"] == null) throw const EngineFailure("invalid_delivery_radius");
    } else {
      row["latitude"] = null;
      row["longitude"] = null;
      row["radius"] = null;
      if ((row["polygon"] as List).length < minPoints) throw const EngineFailure("invalid_delivery_area_polygon");
    }

    return row;
  }

  static String? _member(Object? raw, List<String> set) {
    if (raw is! String) return null;

    final value = raw.trim().toLowerCase();

    return set.contains(value) ? value : null;
  }

  /// An amount in minor units: 0 up to the cloud's ceiling (9,999,999,999 and its decimals).
  int? _amount(Object? raw) {
    if (raw == null) return null;

    var ceiling = 10000000000;
    for (var digit = 0; digit < _business.decimals; digit++) {
      ceiling *= 10;
    }

    if (raw is! int || raw < 0 || raw >= ceiling) throw const EngineFailure("invalid_delivery_fee");

    return raw;
  }

  /// Metres, to the 10 m the cloud's two decimals of a kilometre keep.
  static int? _radius(Object? raw) {
    if (raw == null) return null;
    if (raw is! num || !raw.isFinite) throw const EngineFailure("invalid_delivery_radius");

    final metres = (raw / 10).round() * 10;
    if (metres < minRadius || metres > maxRadius) throw const EngineFailure("invalid_delivery_radius");

    return metres;
  }

  static int? _eta(Object? raw) {
    if (raw == null) return null;
    if (raw is! int || raw < 1 || raw > maxEta) throw const EngineFailure("invalid_delivery_eta");

    return raw;
  }

  /// 0 to 65535; null is the default place.
  static int _position(Object? raw) {
    if (raw == null) return 100;
    if (raw is! int || raw < 0 || raw > 65535) throw const EngineFailure("invalid_order");

    return raw;
  }

  /// A list of names or of `{name, fee}`; the same name typed twice (case and accents aside) is
  /// kept once, the first.
  List<Object?> _zones(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List || raw.length > maxZones) throw const EngineFailure("invalid_delivery_zones");

    final zones = <Object?>[];
    final seen = <String>{};

    for (final item in raw) {
      final entry = item is Map;
      final name = entry ? item["name"] : item;
      if (name is! String) throw const EngineFailure("invalid_delivery_zones");

      final clean = name.replaceAll(RegExp(r"[\x00-\x1F\x7F]"), " ").replaceAll(RegExp(r"\s+"), " ").trim();
      if (clean.isEmpty || clean.length > zoneLength) throw const EngineFailure("invalid_delivery_zones");

      final int? fee;
      try {
        fee = _amount(entry ? item["fee"] : null);
      } on EngineFailure {
        throw const EngineFailure("invalid_delivery_zones");
      }

      if (seen.add(fold(clean).replaceAll(RegExp(r"\s+"), " "))) zones.add({"name": clean, "fee": fee});
    }

    return zones;
  }

  /// An outline of `[latitude, longitude]` pairs or `{latitude, longitude}` objects, in millionths:
  /// a point repeated where it was drawn twice and the closing point are dropped.
  static List<Object?> _ring(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List || raw.length > maxPoints) throw const EngineFailure("invalid_delivery_area_polygon");

    final ring = <List<int>>[];
    for (final entry in raw) {
      final (Object? lat, Object? lng) = switch (entry) {
        [final a, final b, ...] => (a, b),
        {"latitude": final a, "longitude": final b} => (a, b),
        _ => (null, null),
      };
      final latitude = _coordinate(lat, 90);
      final longitude = _coordinate(lng, 180);
      if (latitude == null || longitude == null) throw const EngineFailure("invalid_delivery_area_polygon");

      if (ring.isNotEmpty && ring.last[0] == latitude && ring.last[1] == longitude) continue;
      ring.add([latitude, longitude]);
    }

    if (ring.length > 1 && ring.first[0] == ring.last[0] && ring.first[1] == ring.last[1]) ring.removeLast();
    if (ring.isNotEmpty && ring.length < minPoints) throw const EngineFailure("invalid_delivery_area_polygon");

    return ring;
  }

  /// Degrees within ±[limit], in millionths; null when it isn't one.
  static int? _coordinate(Object? raw, int limit) {
    if (raw is! num || !raw.isFinite || raw.abs() > limit) return null;

    return (raw * 1000000).round();
  }

  static double? _degrees(Object? millionths) => millionths is int ? millionths / 1000000 : null;

  /// A text the company wrote: control characters as spaces, spaces collapsed; null when nothing
  /// is left. Longer than [max], or with a character outside [chars], is refused.
  static String? _text(Object? raw, String field, {required int max, RegExp? chars}) {
    if (raw == null) return null;
    if (raw is! String) throw EngineFailure(ErrorCodes.invalidField, {"field": field});

    final text = raw.replaceAll(RegExp(r"[\x00-\x1F\x7F]"), " ").replaceAll(RegExp(r"\s+"), " ").trim();
    if (text.isEmpty) return null;
    if (text.length > max || (chars != null && !chars.hasMatch(text))) {
      throw EngineFailure(ErrorCodes.invalidField, {"field": field});
    }

    return text;
  }

  // ---------------------------------------------------------------- storage

  ResultSet _live(String table) => _db.select("SELECT * FROM $table WHERE deleted = 0 ORDER BY position, created, id");

  Row _find(String table, Object? id) {
    final row = id is String ? _db.select("SELECT * FROM $table WHERE id = ? AND deleted = 0", [id]).firstOrNull : null;

    return row ?? (throw const EngineFailure(ErrorCodes.notFound));
  }

  void _insert(Database db, String table, Map<String, String> columns, String id, Map<String, Object?> row, Hlc stamp) {
    final values = {
      "id": id,
      for (final MapEntry(key: field, value: column) in columns.entries) column: _stored(row[field]),
      "created": _now().toUtc().toIso8601String(),
      "created_hlc": stamp.pack(),
      "updated_hlc": stamp.pack(),
    };

    db.execute(
      "INSERT INTO $table (${values.keys.join(", ")}) VALUES (${values.keys.map((_) => "?").join(", ")})",
      values.values.toList(),
    );
  }

  /// Writes the fields of [row] that differ from [before], and logs them; nothing changed writes
  /// nothing.
  void _update(Database db, String table, String entity, Map<String, String> columns, String id,
      Map<String, Object?> before, Map<String, Object?> row, {String? actor, String? device}) {
    final changed = {
      for (final field in columns.keys)
        if (jsonEncode(before[field]) != jsonEncode(row[field])) field: row[field],
    };
    if (changed.isEmpty) return;

    final stamp = _clock.tick();
    db.execute(
      "UPDATE $table SET ${[for (final field in changed.keys) "${columns[field]} = ?", "updated_hlc = ?"].join(", ")} WHERE id = ?",
      [for (final value in changed.values) _stored(value), stamp.pack(), id],
    );
    Oplog(db).append(hlc: stamp, entity: entity, entityId: id, kind: "edited", payload: changed, actor: actor, device: device);
  }

  void _remove(String table, String entity, Object? id, {String? actor, String? device}) => _store.write((db) {
    _find(table, id);

    final stamp = _clock.tick();
    db.execute("UPDATE $table SET deleted = 1, updated_hlc = ? WHERE id = ?", [stamp.pack(), id]);
    Oplog(db).append(hlc: stamp, entity: entity, entityId: id! as String, kind: "removed", actor: actor, device: device);
  });

  /// A field as its column holds it: lists as JSON (an empty one as null), flags as 0 or 1.
  static Object? _stored(Object? value) => switch (value) {
    final List<Object?> list => list.isEmpty ? null : jsonEncode(list),
    final bool flag => flag ? 1 : 0,
    _ => value,
  };

  /// A stored option as edge fields.
  static Map<String, Object?> _optionFields(Row row) => {
    for (final MapEntry(key: field, value: column) in optionColumns.entries)
      field: field == "zones" ? _list(row[column]) : row[column],
  };

  /// A stored area as edge fields.
  static Map<String, Object?> _areaFields(Row row) => {
    for (final MapEntry(key: field, value: column) in areaColumns.entries)
      field: switch (field) {
        "polygon" => _list(row[column]),
        "active" => row[column] == 1,
        _ => row[column],
      },
  };

  static List<Object?> _list(Object? json) => json is String ? jsonDecode(json) as List<Object?> : const [];

  Map<String, Object?> _option(Row row) {
    final fields = _optionFields(row);

    return {
      "id": row["id"],
      ...fields,
      "providerName": Carriers.name(fields["provider"] as String?),
      "icon": null,
    };
  }

  static Map<String, Object?> _area(Row row) {
    final fields = _areaFields(row);

    return {
      "id": row["id"],
      ...fields,
      "latitude": _degrees(fields["latitude"]),
      "longitude": _degrees(fields["longitude"]),
      "polygon": [
        for (final point in (fields["polygon"] as List).cast<List>()) [_degrees(point[0]), _degrees(point[1])],
      ],
    };
  }
}
