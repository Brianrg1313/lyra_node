import 'dart:convert';

import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../failure.dart';
import '../../ids.dart';
import '../../net/events.dart';
import '../../net/files.dart';
import '../../oplog/hlc.dart';
import '../../oplog/oplog.dart';
import '../../storage/store.dart';
import 'cells.dart';
import 'spreadsheet.dart';
import 'typing.dart';

part 'importing.dart';

/// Product tables, their fields and records, and the records' images (`inventory.md`).
///
/// Every write joins the running `Store.write` of its op (`OpCall.write`): the change, its oplog
/// entry and its `table/changed` event commit together. A `STOCK` cell is never stored: it is
/// read from `stock_balances`, which only the ledger writes (I-12, `stock.md`).
final class Inventory {
  Inventory(this._store, this._clock, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Store _store;
  final HlcClock _clock;
  final DateTime Function() _now;

  Database get _db => _store.db;

  /// Who reads tables and receives `table/changed`.
  static const viewPermission = "inventory.view";

  /// Images per cell (I-30).
  static const maxImages = 8;

  static const _maxRecordsPage = 200;

  String get _stamp => _now().toUtc().toIso8601String();

  // ---------------------------------------------------------------- tables

  /// `inventory.tables.list`: the live tables, oldest first (`TableLiteModel`).
  List<Map<String, Object?>> tables() => [
    for (final row in _db.select("SELECT * FROM inventory_tables WHERE deleted = 0 ORDER BY id")) _lite(row),
  ];

  /// `inventory.tables.create` (I-1, I-3): the first table is primary; a template adds its fields.
  Map<String, Object?> createTable(Map<String, Object?> args, {String? actor, String? device}) {
    final name = _text(args["title"], "title", max: 80, required: true)!;
    final description = _text(args["description"], "description", max: 500);
    final color = args["color"];
    final template = args["template"] == null ? TableTemplates.blank : _text(args["template"], "template", max: 32)!.toUpperCase();

    if (color is! String || !RegExp(r"^0x[0-9A-Fa-f]{8}$").hasMatch(color)) {
      throw const EngineFailure(ErrorCodes.invalidField, {"field": "color"});
    }
    if (!TableTemplates.exists(template)) throw const EngineFailure("unknown_template");

    final id = newId();

    _store.write((db) {
      final stamp = _clock.tick();
      final primary = db.select("SELECT 1 FROM inventory_tables WHERE deleted = 0 AND is_primary = 1").isEmpty;

      db.execute(
        "INSERT INTO inventory_tables (id, name, description, color, is_primary, created, updated, created_hlc, updated_hlc) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [id, name, description, color, primary ? 1 : 0, _stamp, _stamp, stamp.pack(), stamp.pack()],
      );

      final language = db.select("SELECT language FROM company").firstOrNull?["language"] as String? ?? "en";
      for (final (position, (type, names, unit)) in (TableTemplates.fields[template] ?? const []).indexed) {
        _insertField(db, stamp, id,
          name: TableTemplates.name(names, language),
          type: type,
          position: position,
          unit: unit ?? "",
          summary: const {FieldTypes.title, FieldTypes.sku, FieldTypes.price}.contains(type),
        );
      }

      Oplog(db).append(hlc: stamp, entity: "inventory_table", entityId: id, kind: "created",
        payload: {"name": name, "template": template, "primary": primary}, actor: actor, device: device);
      _tableChanged(db, id, "structure");
    });

    return {"id": id};
  }

  /// `inventory.tables.edit {id, name?, description?, primary?}` (I-3): `primary: true` takes the
  /// flag from the table that held it; it can't be taken off.
  Map<String, Object?> editTable(Map<String, Object?> args, {String? actor, String? device}) {
    final id = _id(args["id"]);
    final changes = <String, Object?>{};

    if (args.containsKey("name")) changes["name"] = _text(args["name"], "name", max: 80, required: true);
    if (args.containsKey("description")) changes["description"] = _text(args["description"], "description", max: 500);
    if (args.containsKey("primary")) {
      if (args["primary"] != true) throw const EngineFailure("invalid_primary");
      changes["is_primary"] = 1;
    }

    _store.write((db) {
      final table = _table(id);
      if (changes.isEmpty) return;

      final stamp = _clock.tick();
      if (changes["is_primary"] == 1 && table["is_primary"] != 1) {
        db.execute("UPDATE inventory_tables SET is_primary = 0, updated_hlc = ? WHERE is_primary = 1", [stamp.pack()]);
      }

      db.execute(
        "UPDATE inventory_tables SET ${changes.keys.map((column) => "$column = ?").join(", ")}, updated = ?, updated_hlc = ? WHERE id = ?",
        [...changes.values, _stamp, stamp.pack(), id],
      );
      Oplog(db).append(hlc: stamp, entity: "inventory_table", entityId: id, kind: "edited",
        payload: {for (final entry in changes.entries) entry.key == "is_primary" ? "primary" : entry.key: entry.value},
        actor: actor, device: device);
      _tableChanged(db, id, "structure");
    });

    return _lite(_table(id));
  }

  /// `inventory.tables.delete {id}` (I-2, I-3): soft; records leave every list, movements stay.
  /// A primary table hands the flag to the oldest one left.
  void deleteTable(String id, {String? actor, String? device}) => _store.write((db) {
    final table = _table(id);
    final stamp = _clock.tick();

    db.execute("UPDATE inventory_tables SET deleted = 1, is_primary = 0, updated = ?, updated_hlc = ? WHERE id = ?",
      [_stamp, stamp.pack(), id]);

    if (table["is_primary"] == 1) {
      db.execute(
        "UPDATE inventory_tables SET is_primary = 1, updated_hlc = ? "
        "WHERE id = (SELECT id FROM inventory_tables WHERE deleted = 0 ORDER BY id LIMIT 1)",
        [stamp.pack()],
      );
    }

    Oplog(db).append(hlc: stamp, entity: "inventory_table", entityId: id, kind: "deleted", payload: const {},
      actor: actor, device: device);
    _tableChanged(db, id, "structure");
  });

  /// `inventory.tables.structure {id}` (`TableStructureModel`): fields in the `{keys, values}` shape.
  Map<String, Object?> structure(String id) {
    final table = _table(id);
    const keys = ["id", "name", "type", "width", "options", "unit"];

    return {
      "id": table["id"],
      "name": table["name"],
      "description": table["description"] ?? "",
      "color": table["color"],
      "date": table["created"],
      "records": _count(id),
      "importStage": table["import_stage"],
      "fields": {
        "keys": keys,
        "values": [
          for (final field in _fields(id))
            [field["id"], field["name"], field["type"], field["width"], _list(field["options"]), field["unit"]],
        ],
      },
    };
  }

  /// `inventory.tables.details {id}` (`TableDetailModel`). Agents and channels are cloud things:
  /// never reached here (I-5).
  Map<String, Object?> details(String id) {
    final table = _table(id);
    final fields = _fields(id);
    final types = <String, int>{};
    final visibility = <String, int>{};

    for (final field in fields) {
      types.update(field["type"] as String, (count) => count + 1, ifAbsent: () => 1);
      visibility.update(field["visibility"] as String, (count) => count + 1, ifAbsent: () => 1);
    }

    const keys = ["id", "name", "description", "position", "type", "options", "unit", "visibility", "summary", "date", "updated"];

    return {
      "id": table["id"],
      "name": table["name"],
      "description": table["description"] ?? "",
      "color": table["color"],
      "date": table["created"],
      "updated": table["updated"],
      "primary": table["is_primary"] == 1,
      "records": {"total": _count(id), "last": table["last_record"]},
      "columns": {
        "total": fields.length,
        "types": types,
        "visibility": visibility,
        "summary": fields.where((field) => field["summary"] == 1).length,
        "untyped": 0,
      },
      "agent": {
        "searchable": false,
        "filterable": 0,
        "stock": types.containsKey(FieldTypes.stock),
        "image": types.containsKey(FieldTypes.image),
      },
      "channels": const {"reached": false, "linked": <Object?>[], "open": <Object?>[]},
      "fields": {
        "keys": keys,
        "values": [
          for (final field in fields)
            [field["id"], field["name"], field["description"] ?? "", field["position"], field["type"],
              _list(field["options"]), field["unit"], field["visibility"], field["summary"] == 1, field["created"], field["updated"]],
        ],
      },
    };
  }

  // ---------------------------------------------------------------- fields

  /// `inventory.fields.create` (I-10, I-13, I-15): inserted at `position`, the rest shift.
  Map<String, Object?> createField(Map<String, Object?> args, {String? actor, String? device}) {
    final tableId = _id(args["tableId"], field: "tableId");
    final name = _text(args["name"], "name", max: 60, required: true)!;
    final description = _text(args["description"], "description", max: 500);
    final type = _type(args["type"]);
    final position = args["position"];
    if (position is! int || position < 0) throw const EngineFailure(ErrorCodes.invalidField, {"field": "position"});

    final id = _store.write((db) {
      _table(tableId);
      _single(tableId, type);

      final stamp = _clock.tick();
      final count = _fields(tableId).length;
      final at = position.clamp(0, count);

      db.execute("UPDATE inventory_fields SET position = position + 1 WHERE table_id = ? AND position >= ?", [tableId, at]);
      final id = _insertField(db, stamp, tableId,
        name: name,
        description: description,
        type: type,
        position: at,
        options: FieldTypes.listed.contains(type) ? _options(args["options"]) : const [],
        unit: _unit(type, args["unit"]),
      );

      if (type == FieldTypes.counter) _numberRecords(db, tableId, id);

      Oplog(db).append(hlc: stamp, entity: "inventory_field", entityId: id, kind: "created",
        payload: {"table": tableId, "name": name, "type": type, "position": at}, actor: actor, device: device);
      _touchTable(db, stamp, tableId);
      _tableChanged(db, tableId, "structure");

      return id;
    });

    return _fieldJson(_field(id));
  }

  /// Whether `inventory.fields.edit` [args] only drag the column's width (I-17): a `name` equal
  /// to the current one is not a change.
  bool onlyWidth(Map<String, Object?> args) {
    final id = args["id"];
    if (id is! String) return false;

    final rows = _db.select("SELECT name FROM inventory_fields WHERE id = ?", [id]);
    if (rows.isEmpty) return false;

    return args.keys.every((key) => key == "id" || key == "width" || key == "name" && args[key] == rows.first["name"]);
  }

  /// `inventory.fields.edit {id, changed keys}` (I-10, I-13 to I-15, I-17).
  Map<String, Object?> editField(Map<String, Object?> args, {String? actor, String? device, int? decimals}) {
    final id = _id(args["id"]);

    _store.write((db) {
      final field = _field(id);
      final tableId = field["table_id"] as String;
      final changes = <String, Object?>{};
      final oldType = field["type"] as String;
      var type = oldType;

      if (args.containsKey("name")) changes["name"] = _text(args["name"], "name", max: 60, required: true);
      if (args.containsKey("description")) changes["description"] = _text(args["description"], "description", max: 500);
      if (args.containsKey("type")) {
        type = _type(args["type"]);
        if (type != oldType) {
          _single(tableId, type, except: id);
          changes["type"] = type;
          changes["hand_typed"] = 1;
        }
      }
      if (args.containsKey("width")) {
        final width = args["width"];
        if (width != null && (width is! int || width < 16 || width > 2000)) {
          throw const EngineFailure(ErrorCodes.invalidField, {"field": "width"});
        }
        changes["width"] = width;
      }
      if (args.containsKey("visibility")) {
        final visibility = args["visibility"];
        if (visibility is! String || !FieldVisibility.all.contains(visibility)) {
          throw const EngineFailure(ErrorCodes.invalidField, {"field": "visibility"});
        }
        changes["visibility"] = visibility;
      }
      if (args.containsKey("summary")) {
        final summary = args["summary"];
        if (summary is! bool && summary != 0 && summary != 1) throw const EngineFailure(ErrorCodes.invalidField, {"field": "summary"});
        changes["summary"] = summary == true || summary == 1 ? 1 : 0;
      }
      if (args.containsKey("options") && FieldTypes.listed.contains(type)) changes["options"] = jsonEncode(_options(args["options"]));
      if (args.containsKey("unit") || changes.containsKey("type")) {
        changes["unit"] = _unit(type, args.containsKey("unit") ? args["unit"] : field["unit"]);
      }

      final stamp = _clock.tick();

      if (args.containsKey("position")) {
        final position = args["position"];
        if (position is! int || position < 0) throw const EngineFailure(ErrorCodes.invalidField, {"field": "position"});

        final from = field["position"] as int;
        final to = position.clamp(0, _fields(tableId).length - 1);
        if (to < from) {
          db.execute("UPDATE inventory_fields SET position = position + 1 WHERE table_id = ? AND position >= ? AND position < ?", [tableId, to, from]);
        } else if (to > from) {
          db.execute("UPDATE inventory_fields SET position = position - 1 WHERE table_id = ? AND position > ? AND position <= ?", [tableId, from, to]);
        }
        changes["position"] = to;
      }

      if (changes.isEmpty) return;

      db.execute(
        "UPDATE inventory_fields SET ${changes.keys.map((column) => "$column = ?").join(", ")}, updated = ?, updated_hlc = ? WHERE id = ?",
        [...changes.values, _stamp, stamp.pack(), id],
      );

      if (changes.containsKey("type")) _retype(db, tableId, id, type, decimals: decimals ?? 2);

      Oplog(db).append(hlc: stamp, entity: "inventory_field", entityId: id, kind: "edited",
        payload: {for (final entry in changes.entries) if (entry.key != "hand_typed") entry.key: entry.value},
        actor: actor, device: device);
      _touchTable(db, stamp, tableId);
      _tableChanged(db, tableId, changes.containsKey("type") ? "records" : "structure");
    });

    return _fieldJson(_field(id));
  }

  /// `inventory.fields.delete {id}` (I-13, I-16): the column and its values go; the gap closes.
  /// Answers what the audit log records.
  ({String table, String name, int values}) deleteField(String id, {String? actor, String? device}) => _store.write((db) {
    final field = _field(id);
    final tableId = field["table_id"] as String;
    final path = _path(id);
    final values = db.select(
      "SELECT count(*) AS n FROM inventory_records WHERE table_id = ? AND deleted = 0 AND json_extract(data, ?) IS NOT NULL",
      [tableId, path],
    ).first["n"] as int;
    final stamp = _clock.tick();

    db.execute("DELETE FROM inventory_fields WHERE id = ?", [id]);
    db.execute("UPDATE inventory_fields SET position = position - 1 WHERE table_id = ? AND position > ?", [tableId, field["position"]]);
    db.execute("UPDATE inventory_records SET data = json_remove(data, ?) WHERE table_id = ?", [path, tableId]);

    Oplog(db).append(hlc: stamp, entity: "inventory_field", entityId: id, kind: "deleted",
      payload: {"table": tableId, "name": field["name"], "values": values}, actor: actor, device: device);
    _touchTable(db, stamp, tableId);
    _tableChanged(db, tableId, "structure");

    return (table: tableId, name: field["name"] as String, values: values);
  });

  // ---------------------------------------------------------------- records

  /// `inventory.records.list` (I-25, I-26): the `TableViewModel` shape, the record id first and
  /// one column per field id, in position order.
  Map<String, Object?> records(String tableId, {required int page, required int size, String match = ""}) {
    _table(tableId);
    if (page < 1) throw const EngineFailure(ErrorCodes.invalidField, {"field": "page"});
    if (size < 1 || size > _maxRecordsPage) throw const EngineFailure(ErrorCodes.invalidField, {"field": "size"});

    final fields = _fields(tableId);
    final (where, arguments) = _match(tableId, fields, match);
    final total = _db.select("SELECT count(*) AS n FROM inventory_records r WHERE $where", arguments).first["n"] as int;
    final rows = _db.select(
      "SELECT r.id, r.data, b.on_hand - b.reserved AS available FROM inventory_records r "
      "LEFT JOIN stock_balances b ON b.product_id = r.id WHERE $where ORDER BY r.id LIMIT ? OFFSET ?",
      [...arguments, size, (page - 1) * size],
    );

    return {
      "keys": ["id", for (final field in fields) field["id"]],
      "values": [
        for (final row in rows)
          [row["id"], ..._cells(fields, jsonDecode(row["data"] as String) as Map<String, Object?>, row["available"] as int?)],
      ],
      "page": page,
      "size": size,
      "total": total,
    };
  }

  /// `inventory.records.create {tableId, data}` (I-11, I-20 to I-22).
  Map<String, Object?> createRecord(String tableId, Object? data, {required int decimals, String? actor, String? device}) {
    final values = _data(data);
    final id = newId();

    _store.write((db) {
      final table = _table(tableId);
      final fields = {for (final field in _fields(tableId)) field["id"] as String: field};
      final cells = _checked(tableId, fields, values, decimals: decimals);
      final stamp = _clock.tick();

      for (final field in fields.values.where((field) => field["type"] == FieldTypes.counter)) {
        cells[field["id"] as String] = table["next_counter"] as int;
        db.execute("UPDATE inventory_tables SET next_counter = next_counter + 1 WHERE id = ?", [tableId]);
      }

      db.execute(
        "INSERT INTO inventory_records (id, table_id, data, created, updated, created_by, updated_by, created_hlc, updated_hlc) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [id, tableId, jsonEncode(cells), _stamp, _stamp, actor, actor, stamp.pack(), stamp.pack()],
      );
      Oplog(db).append(hlc: stamp, entity: "inventory_record", entityId: id, kind: "created",
        payload: {"table": tableId, "data": cells}, actor: actor, device: device);
      _recordWritten(db, stamp, tableId);
    });

    return {"id": id};
  }

  /// `inventory.records.edit {tableId, id, data}` (I-20 to I-22, I-24): only the changed cells.
  void editRecord(String tableId, String id, Object? data, {required int decimals, String? actor, String? device}) {
    final values = _data(data);

    _store.write((db) {
      _table(tableId);
      final record = _record(tableId, id);
      final fields = {for (final field in _fields(tableId)) field["id"] as String: field};
      final cells = _checked(tableId, fields, values, decimals: decimals, except: id);
      final stored = jsonDecode(record["data"] as String) as Map<String, Object?>;
      final stamp = _clock.tick();

      for (final entry in cells.entries) {
        if (entry.value == null) {
          stored.remove(entry.key);
        } else {
          stored[entry.key] = entry.value;
        }
      }

      db.execute("UPDATE inventory_records SET data = ?, updated = ?, updated_by = ?, updated_hlc = ? WHERE id = ?",
        [jsonEncode(stored), _stamp, actor, stamp.pack(), id]);
      Oplog(db).append(hlc: stamp, entity: "inventory_record", entityId: id, kind: "edited",
        payload: {"table": tableId, "data": cells}, actor: actor, device: device);
      _recordWritten(db, stamp, tableId);
    });
  }

  /// `inventory.records.delete {tableId, id}` (I-23): soft; its movements stay.
  void deleteRecord(String tableId, String id, {String? actor, String? device}) => _store.write((db) {
    _table(tableId);
    _record(tableId, id);
    final stamp = _clock.tick();

    db.execute("UPDATE inventory_records SET deleted = 1, updated = ?, updated_by = ?, updated_hlc = ? WHERE id = ?",
      [_stamp, actor, stamp.pack(), id]);
    Oplog(db).append(hlc: stamp, entity: "inventory_record", entityId: id, kind: "deleted",
      payload: {"table": tableId}, actor: actor, device: device);
    _recordWritten(db, stamp, tableId);
  });

  // ---------------------------------------------------------------- images

  /// `inventory.images.add {tableId, productId, fileId}` (I-30, I-31): the upload joins the end
  /// of the table's image cell, readable by whoever reads the table.
  Map<String, Object?> addImage(String tableId, String productId, String fileId, FileStore files,
      {required String actor, String? device}) => _store.write((db) {
    final field = _imageField(tableId);
    final images = _images(_record(tableId, productId), field);

    if (images.length >= maxImages) throw const EngineFailure("too_many_images", {"max": maxImages});

    files.claim(fileId, FilePurpose.productImage, permission: viewPermission, uploader: actor);

    return _writeImages(db, tableId, productId, field, [...images, fileId], actor: actor, device: device);
  });

  /// `inventory.images.remove {tableId, productId, fileId}`: the file is let go (the orphan sweep
  /// deletes it); an import's external address is just taken out (I-32).
  Map<String, Object?> removeImage(String tableId, String productId, String fileId, FileStore files,
      {String? actor, String? device}) => _store.write((db) {
    final field = _imageField(tableId);
    final images = _images(_record(tableId, productId), field);

    if (!images.contains(fileId)) throw const EngineFailure(ErrorCodes.notFound);
    if (!fileId.contains("://")) files.release(fileId);

    return _writeImages(db, tableId, productId, field, [...images]..remove(fileId), actor: actor, device: device);
  });

  // ---------------------------------------------------------------- reads for the ledger

  /// The live record [productId] with what the ledger freezes on a movement, or null.
  ({String table, String? name, String? sku, bool tracked})? product(String productId) {
    final rows = _db.select(
      "SELECT r.table_id, r.data FROM inventory_records r JOIN inventory_tables t ON t.id = r.table_id "
      "WHERE r.id = ? AND r.deleted = 0 AND t.deleted = 0",
      [productId],
    );
    if (rows.isEmpty) return null;

    final tableId = rows.first["table_id"] as String;
    final data = jsonDecode(rows.first["data"] as String) as Map<String, Object?>;
    final fields = _fields(tableId);
    String? first(String type) {
      final field = fields.where((field) => field["type"] == type).firstOrNull;
      return field == null ? null : data[field["id"]]?.toString();
    }

    return (
      table: tableId,
      name: first(FieldTypes.title),
      sku: first(FieldTypes.sku),
      tracked: fields.any((field) => field["type"] == FieldTypes.stock),
    );
  }

  /// The primary table, or null when the company has none.
  Row? get primaryTable => _db.select("SELECT * FROM inventory_tables WHERE deleted = 0 AND is_primary = 1").firstOrNull;

  /// [tableId]'s fields in position order.
  List<Row> fieldsOf(String tableId) => _fields(tableId);

  /// The cells of [data] in [fields]' order, with a `STOCK` cell read from the ledger (I-12).
  List<Object?> cellsOf(List<Row> fields, Map<String, Object?> data, int? available) => _cells(fields, data, available);

  /// The SQL condition over `inventory_records r` for [tableId]'s live records matching [match].
  (String, List<Object?>) matchOf(String tableId, List<Row> fields, String match) => _match(tableId, fields, match);

  // ---------------------------------------------------------------- internals

  String _insertField(Database db, Hlc stamp, String tableId, {
    required String name,
    required String type,
    required int position,
    String? description,
    List<String> options = const [],
    String unit = "",
    bool summary = false,
    bool handTyped = true,
  }) {
    final id = newId();

    db.execute(
      "INSERT INTO inventory_fields (id, table_id, name, description, type, position, options, unit, summary, hand_typed, "
      "created, updated, created_hlc, updated_hlc) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [id, tableId, name, description, type, position, jsonEncode(options), unit, summary ? 1 : 0, handTyped ? 1 : 0,
        _stamp, _stamp, stamp.pack(), stamp.pack()],
    );

    return id;
  }

  /// A new `COUNTER` numbers the records that exist, in creation order (I-11).
  void _numberRecords(Database db, String tableId, String fieldId) {
    final path = _path(fieldId);
    var next = _table(tableId)["next_counter"] as int;

    for (final row in db.select("SELECT id FROM inventory_records WHERE table_id = ? ORDER BY id", [tableId])) {
      db.execute("UPDATE inventory_records SET data = json_set(data, ?, ?) WHERE id = ?", [path, next++, row["id"]]);
    }
    db.execute("UPDATE inventory_tables SET next_counter = ? WHERE id = ?", [next, tableId]);
  }

  /// A type change re-reads each stored value as text under the new type; what doesn't fit is
  /// kept as that text (I-14). A new `COUNTER` numbers the records (I-11).
  void _retype(Database db, String tableId, String fieldId, String type, {required int decimals}) {
    final path = _path(fieldId);

    if (type == FieldTypes.counter) return _numberRecords(db, tableId, fieldId);
    if (type == FieldTypes.stock) return;

    for (final row in db.select(
      "SELECT id, json_extract(data, ?) AS value, json_type(data, ?) AS kind FROM inventory_records WHERE table_id = ? AND json_type(data, ?) IS NOT NULL",
      [path, path, tableId, path],
    )) {
      final raw = row["kind"] == "array" ? jsonDecode(row["value"] as String) : row["value"];
      final text = Cells.asText(raw is int && row["kind"] == "true" ? true : raw is int && row["kind"] == "false" ? false : raw);
      final value = type == FieldTypes.image ? _imageText(raw) : Cells.read(type, text, decimals: decimals) ?? text;

      db.execute("UPDATE inventory_records SET data = json_set(data, ?, json(?)) WHERE id = ?", [path, jsonEncode(value), row["id"]]);
    }
  }

  /// Text turned into an image cell: the addresses it holds, kept as external images (I-32).
  static List<String> _imageText(Object? raw) => [
    for (final part in (raw is List ? raw : "$raw".split(RegExp(r"[\s,;|]+"))))
      if ("$part".contains("://")) "$part",
  ];

  Map<String, Object?> _writeImages(Database db, String tableId, String productId, Row field, List<String> images,
      {String? actor, String? device}) {
    final stamp = _clock.tick();
    final path = _path(field["id"] as String);

    db.execute(
      "UPDATE inventory_records SET data = ${images.isEmpty ? "json_remove(data, ?)" : "json_set(data, ?, json(?))"}, "
      "updated = ?, updated_by = ?, updated_hlc = ? WHERE id = ?",
      [path, if (images.isNotEmpty) jsonEncode(images), _stamp, actor, stamp.pack(), productId],
    );
    Oplog(db).append(hlc: stamp, entity: "inventory_record", entityId: productId, kind: "edited",
      payload: {"table": tableId, "data": {field["id"]: images}}, actor: actor, device: device);
    _recordWritten(db, stamp, tableId);

    return {
      "images": [
        for (final image in images)
          image.contains("://") ? {"id": null, "url": image} : {"id": image},
      ],
    };
  }

  /// The table's image cell: its first `IMAGE` field.
  Row _imageField(String tableId) {
    _table(tableId);

    return _fields(tableId).where((field) => field["type"] == FieldTypes.image).firstOrNull ??
      (throw const EngineFailure(ErrorCodes.invalidField, {"field": "image"}));
  }

  static List<String> _images(Row record, Row field) {
    final value = (jsonDecode(record["data"] as String) as Map)[field["id"]];

    return value is List ? [for (final image in value) "$image"] : const [];
  }

  /// [values] checked against [fields] (I-20 to I-22): answers the cells to store, null to clear.
  Map<String, Object?> _checked(String tableId, Map<String, Row> fields, Map<String, Object?> values, {
    required int decimals,
    String? except,
  }) {
    final cells = <String, Object?>{};

    for (final entry in values.entries) {
      final field = fields[entry.key];
      if (field == null) throw EngineFailure(ErrorCodes.invalidField, {"field": entry.key});

      final type = field["type"] as String;
      final value = Cells.check(type, entry.value, field: entry.key, decimals: InventoryImport._places(field, decimals));

      if (type == FieldTypes.sku && value != null) _uniqueSku(tableId, entry.key, value as String, except: except);

      cells[entry.key] = value;
    }

    return cells;
  }

  /// SKUs are unique within a table, trimmed and without case (I-22).
  void _uniqueSku(String tableId, String fieldId, String sku, {String? except}) {
    final taken = _db.select(
      "SELECT 1 FROM inventory_records WHERE table_id = ? AND deleted = 0 AND id IS NOT ? "
      "AND lower(trim(json_extract(data, ?))) = lower(trim(?))",
      [tableId, except, _path(fieldId), sku],
    );

    if (taken.isNotEmpty) throw EngineFailure("duplicate_sku", {"field": fieldId, "sku": sku});
  }

  static Map<String, Object?> _data(Object? data) {
    if (data is! Map) throw const EngineFailure(ErrorCodes.invalidField, {"field": "data"});

    return {for (final entry in data.entries) "${entry.key}": entry.value};
  }

  List<Object?> _cells(List<Row> fields, Map<String, Object?> data, int? available) => [
    for (final field in fields)
      field["type"] == FieldTypes.stock ? available ?? 0 : data[field["id"]],
  ];

  (String, List<Object?>) _match(String tableId, List<Row> fields, String match) {
    final text = fold(match.trim());
    final searchable = [
      for (final field in fields)
        if (FieldTypes.searchable.contains(field["type"])) field["id"] as String,
    ];

    if (text.isEmpty) return ("r.table_id = ? AND r.deleted = 0", [tableId]);
    if (searchable.isEmpty) return ("0", const []);

    final pattern = "%${text.replaceAll(r"\", r"\\").replaceAll("%", r"\%").replaceAll("_", r"\_")}%";

    return (
      "r.table_id = ? AND r.deleted = 0 AND EXISTS (SELECT 1 FROM json_each(r.data) j "
        "WHERE j.key IN (${List.filled(searchable.length, "?").join(", ")}) AND fold(j.value) LIKE ? ESCAPE '\\')",
      [tableId, ...searchable, pattern],
    );
  }

  /// A write on [tableId]'s records: its last-record time, and `table/changed`.
  void _recordWritten(Database db, Hlc stamp, String tableId) {
    db.execute("UPDATE inventory_tables SET last_record = ?, updated_hlc = ? WHERE id = ?", [_stamp, stamp.pack(), tableId]);
    _tableChanged(db, tableId, "records");
  }

  void _touchTable(Database db, Hlc stamp, String tableId) =>
    db.execute("UPDATE inventory_tables SET updated = ?, updated_hlc = ? WHERE id = ?", [_stamp, stamp.pack(), tableId]);

  void _tableChanged(Database db, String tableId, String what) =>
    EventLog.append(db, Events.tableChanged, {"id": tableId, "what": what}, at: _now(), permission: viewPermission);

  Map<String, Object?> _lite(Row row) => {
    "id": row["id"],
    "title": row["name"],
    "description": row["description"] ?? "",
    "color": row["color"],
    "fields": _db.select("SELECT count(*) AS n FROM inventory_fields WHERE table_id = ?", [row["id"]]).first["n"],
    "records": _count(row["id"] as String),
    "primary": row["is_primary"] == 1,
    "created": row["created"],
    "updated": row["updated"],
    "lastRecord": row["last_record"],
    "importStage": row["import_stage"],
  };

  Map<String, Object?> _fieldJson(Row field) => {
    "id": field["id"],
    "tableId": field["table_id"],
    "name": field["name"],
    "description": field["description"],
    "type": field["type"],
    "position": field["position"],
    "width": field["width"],
    "options": _list(field["options"]),
    "unit": field["unit"],
    "visibility": field["visibility"],
    "summary": field["summary"] == 1,
    "created": field["created"],
    "updated": field["updated"],
  };

  int _count(String tableId) =>
    _db.select("SELECT count(*) AS n FROM inventory_records WHERE table_id = ? AND deleted = 0", [tableId]).first["n"] as int;

  Row _table(String id) =>
    _db.select("SELECT * FROM inventory_tables WHERE id = ? AND deleted = 0", [id]).firstOrNull ??
      (throw const EngineFailure(ErrorCodes.notFound));

  Row _field(String id) =>
    _db.select(
      "SELECT f.* FROM inventory_fields f JOIN inventory_tables t ON t.id = f.table_id WHERE f.id = ? AND t.deleted = 0",
      [id],
    ).firstOrNull ?? (throw const EngineFailure(ErrorCodes.notFound));

  Row _record(String tableId, String id) =>
    _db.select("SELECT * FROM inventory_records WHERE id = ? AND table_id = ? AND deleted = 0", [id, tableId]).firstOrNull ??
      (throw const EngineFailure(ErrorCodes.notFound));

  List<Row> _fields(String tableId) =>
    _db.select("SELECT * FROM inventory_fields WHERE table_id = ? ORDER BY position", [tableId]).toList();

  /// At most one `STOCK` and one `COUNTER` per table (I-10).
  void _single(String tableId, String type, {String? except}) {
    if (!FieldTypes.readOnly.contains(type)) return;

    final taken = _db.select("SELECT 1 FROM inventory_fields WHERE table_id = ? AND type = ? AND id IS NOT ?", [tableId, type, except]);
    if (taken.isNotEmpty) throw EngineFailure("duplicate_field_type", {"type": type});
  }

  /// The JSON path of a field's cell. Field ids are UUIDs, quoted anyway.
  static String _path(String fieldId) => '\$."$fieldId"';

  static String _id(Object? raw, {String field = "id"}) {
    if (raw == null) throw EngineFailure(ErrorCodes.required, {"field": field});
    if (raw is! String || raw.length > 64) throw EngineFailure(ErrorCodes.invalidField, {"field": field});

    return raw;
  }

  static String _type(Object? raw) =>
    FieldTypes.from(raw) ?? (throw const EngineFailure(ErrorCodes.invalidField, {"field": "type"}));

  static String? _text(Object? raw, String field, {required int max, bool required = false}) {
    if (raw != null && raw is! String) throw EngineFailure(ErrorCodes.invalidField, {"field": field});

    final value = (raw as String?)?.trim() ?? "";
    if (value.isEmpty) {
      if (required) throw EngineFailure(ErrorCodes.required, {"field": field});
      return null;
    }
    if (value.length > max) throw EngineFailure(ErrorCodes.invalidField, {"field": field});

    return value;
  }

  /// Trimmed, empty ones dropped, duplicates (without case) dropped (I-15).
  static List<String> _options(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List) throw const EngineFailure(ErrorCodes.invalidField, {"field": "options"});

    final kept = <String>[];
    for (final option in raw) {
      final text = "$option".trim();
      if (text.isEmpty || text.length > 120) continue;
      if (kept.any((other) => fold(other) == fold(text))) continue;
      kept.add(text);
    }
    if (kept.length > 500) throw const EngineFailure(ErrorCodes.invalidField, {"field": "options"});

    return kept;
  }

  /// A price's unit is a currency code; a measure's, a short magnitude; other types have none.
  static String _unit(String type, Object? raw) {
    if (!FieldTypes.withUnit.contains(type) || raw == null) return "";
    if (raw is! String) throw const EngineFailure(ErrorCodes.invalidField, {"field": "unit"});

    final unit = raw.trim();
    if (unit.isEmpty) return "";
    if (type != FieldTypes.measure) {
      if (!Catalogs.hasCurrency(unit.toUpperCase())) throw const EngineFailure(ErrorCodes.invalidField, {"field": "unit"});
      return unit.toUpperCase();
    }
    if (unit.length > 16) throw const EngineFailure(ErrorCodes.invalidField, {"field": "unit"});

    return unit;
  }

  static List<String> _list(Object? raw) => [for (final option in jsonDecode(raw as String) as List) "$option"];
}
