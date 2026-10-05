import 'dart:convert';

import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../audit/audit_log.dart';
import '../domain/business/business.dart';
import '../domain/inventory/inventory.dart';
import '../domain/stock/stock.dart';
import '../failure.dart';
import '../identity/grants.dart';
import '../net/events.dart';
import '../oplog/hlc.dart';
import '../oplog/oplog.dart';
import 'edge.dart';

/// The `device` of every oplog entry a pulled change wrote: the push skips them (no echo), and
/// the field clocks take the cloud's stamp for them, not the local one.
const edgeOrigin = "cloud";

/// A record or fact as the wire sees it: [fields] by their edge names, refs as **local** ids;
/// [cells] (a product's) keyed by local field ids.
final class EdgeRow {
  const EdgeRow({required this.fields, this.cells = const {}, required this.hlc, this.deleted = false, this.voided});

  final Map<String, Object?> fields;
  final Map<String, Object?> cells;

  /// The row's last stamp: what the snapshot sends it with.
  final Hlc hlc;
  final bool deleted;

  /// A voided fact's `{reason, at}` and its stamp.
  final (Map<String, Object?>, Hlc)? voided;
}

/// What one oplog entry did to one synced record, in edge terms: the fields and cells it wrote
/// (null: all of them). An entry may touch several records (a table made with its fields).
final class EdgeTouch {
  const EdgeTouch(this.entity, this.id, this.op, {this.fields, this.cells});

  final String entity;
  final String id;
  final String op;
  final Set<String>? fields;
  final Set<String>? cells;
}

/// A pulled change, settled field by field, ready to write: [fields] and [cells] are only the
/// winners, with local ids. [stamp] is the local clock's, for `updated_hlc` and the oplog.
final class EdgeWrite {
  const EdgeWrite({
    required this.id,
    required this.created,
    required this.op,
    required this.fields,
    required this.cells,
    required this.stamp,
    required this.commandId,
    required this.now,
    this.actor,
    this.device = edgeOrigin,
    this.actorAccount,
  });

  final String id;
  final bool created;
  final String op;
  final Map<String, Object?> fields;
  final Map<String, Object?> cells;
  final Hlc stamp;
  final String commandId;
  final DateTime now;

  /// The person's e-mail, as the cloud sent it.
  final String? actor;

  /// The oplog entry's device: [edgeOrigin] for a pulled change, so it isn't pushed back; null
  /// for a value the owner put back from the conflicts inbox, which is pushed like any edit.
  final String? device;
  final String? actorAccount;
}

/// One entity of the edge vocabulary (`task-edge-sync-backend.md` §11) mapped onto the engine's
/// tables: how to read it, what an oplog entry touched, and how to write what the cloud sent.
/// A pulled change is written straight into the tables, as the domain would (its oplog entry with
/// [edgeOrigin], its events), not through the domain's ops: the cloud already checked it, and a
/// field-level merge isn't an op the domains have.
abstract base class EdgeEntity {
  const EdgeEntity();

  /// The edge name.
  String get name;

  /// The oplog's name.
  String get local;

  /// Append-only: never conflicts, never edited after (§9.3).
  bool get fact => false;

  /// Its id is a natural key (a currency's code), the same on both sides: never mapped.
  bool get natural => false;

  /// Whether the cloud's changes to it are applied here: people aren't (who may do what is the
  /// cloud's word, and doesn't travel in this version).
  bool get pulls => true;

  /// Fields holding an id of another entity: field → that entity's edge name.
  Map<String, String> get refs => const {};

  /// The entity a product's cell keys are ids of; null for entities without cells.
  String? get cellsOf => null;

  /// Every live record, for the first upload.
  List<String> ids(Database db);

  EdgeRow? read(Database db, String id);

  /// What [entry] touched; empty when it is nothing the sync carries.
  List<EdgeTouch> touched(Database db, OplogEntry entry);

  /// Writes a pulled change; answers the local id (a created fact may get its own). Throws an
  /// [EngineFailure] to refuse it.
  String apply(Database db, EdgeWrite write);

  void log(Database db, EdgeWrite write, String kind, [Map<String, Object?> payload = const {}]) => Oplog(db).append(
    hlc: write.stamp, entity: local, entityId: write.id, kind: kind, payload: payload, device: write.device,
    actor: write.actorAccount,
  );

  static Never invalid(String field) => throw EngineFailure(ErrorCodes.invalidField, {"field": field});
}

/// How a column's value travels.
enum EdgeKind { text, integer, boolean, json, real }

/// A column under its edge name, with the conversion both ways.
final class EdgeColumn {
  const EdgeColumn(this.name, [this.kind = EdgeKind.text]);

  final String name;
  final EdgeKind kind;

  Object? out(Object? value) => value == null ? null : switch (kind) {
    EdgeKind.boolean => value == 1,
    EdgeKind.json => jsonDecode(value as String),
    _ => value,
  };

  Object? into(Object? value, String field) {
    if (value == null) return null;

    return switch (kind) {
      EdgeKind.text => value is String ? value : EdgeEntity.invalid(field),
      EdgeKind.integer => value is int ? value : EdgeEntity.invalid(field),
      EdgeKind.real => value is num ? value.toDouble() : EdgeEntity.invalid(field),
      EdgeKind.boolean => value is bool ? (value ? 1 : 0) : EdgeEntity.invalid(field),
      EdgeKind.json => jsonEncode(value),
    };
  }
}

/// A record stored one field per column.
abstract base class _ColumnEntity extends EdgeEntity {
  const _ColumnEntity();

  String get sqlTable;
  Map<String, EdgeColumn> get columns;
  String get key => "id";
  bool get softDelete => true;

  /// Columns that must hold a value when the record is made here from the cloud.
  Set<String> get required => const {};

  @override
  List<String> ids(Database db) => [
    for (final row in db.select("SELECT $key AS id FROM $sqlTable${softDelete ? " WHERE deleted = 0" : ""}")) row["id"] as String,
  ];

  @override
  EdgeRow? read(Database db, String id) {
    final row = db.select("SELECT * FROM $sqlTable WHERE $key = ?", [id]).firstOrNull;
    if (row == null) return null;

    return EdgeRow(
      fields: {for (final MapEntry(key: field, value: column) in columns.entries) field: column.out(row[column.name])},
      hlc: Hlc.parse(row["updated_hlc"] as String),
      deleted: softDelete && row["deleted"] == 1,
    );
  }

  /// The [write]'s fields as `column = value`.
  Map<String, Object?> sql(EdgeWrite write) => {
    for (final MapEntry(key: field, value: value) in write.fields.entries)
      if (columns[field] case final column?) column.name: column.into(value, field),
  };

  void update(Database db, EdgeWrite write, Map<String, Object?> values) {
    db.execute(
      "UPDATE $sqlTable SET ${[...values.keys.map((column) => "$column = ?"), "updated_hlc = ?"].join(", ")} WHERE $key = ?",
      [...values.values, write.stamp.pack(), write.id],
    );
  }

  void checkRequired(Map<String, Object?> values) {
    for (final field in required) {
      if (values[columns[field]!.name] == null) EdgeEntity.invalid(field);
    }
  }

  Set<String> known(Iterable<String> keys) => {for (final key in keys) if (columns.containsKey(key)) key};
}

// ------------------------------------------------------------------------------- business

/// The company (`business.md`): mapped at the enrolment, never made from a pulled change.
final class CompanyEdge extends _ColumnEntity {
  const CompanyEdge(this.now);

  final DateTime Function() now;

  @override
  String get name => "company";

  @override
  String get local => "company";

  @override
  String get sqlTable => "company";

  @override
  Map<String, EdgeColumn> get columns => const {
    "name": EdgeColumn("name"), "legalName": EdgeColumn("legal_name"), "nickname": EdgeColumn("nickname"),
    "caption": EdgeColumn("caption"), "activity": EdgeColumn("activity"), "taxId": EdgeColumn("tax_id"),
    "country": EdgeColumn("country"), "language": EdgeColumn("language"), "currency": EdgeColumn("currency"),
    "phone": EdgeColumn("phone"), "website": EdgeColumn("website"), "incorporationDate": EdgeColumn("incorporation_date"),
    "timezone": EdgeColumn("timezone"),
    // The delivery settings live on the company, on both sides (`deliveries.md`).
    "delivers": EdgeColumn("delivers", EdgeKind.boolean), "pickup": EdgeColumn("pickup", EdgeKind.boolean),
    "meetingPoint": EdgeColumn("meeting_point", EdgeKind.boolean), "deliveryNotes": EdgeColumn("delivery_notes"),
  };

  @override
  List<EdgeTouch> touched(Database db, OplogEntry entry) => switch (entry.kind) {
    "created" => [EdgeTouch(name, entry.entityId, EdgeOps.upsert)],
    "edited" when known(entry.payload.keys).isNotEmpty =>
      [EdgeTouch(name, entry.entityId, EdgeOps.upsert, fields: known(entry.payload.keys))],
    _ => const [],
  };

  @override
  String apply(Database db, EdgeWrite write) {
    if (write.created || write.op != EdgeOps.upsert) throw const EngineFailure("unknown_company");

    final values = sql(write);
    for (final column in const ["name", "country", "language", "currency", "meeting_point"]) {
      if (values.containsKey(column) && values[column] == null) EdgeEntity.invalid(column);
    }

    if (values.isNotEmpty) {
      update(db, write, values);
      log(db, write, "edited", write.fields);
      EventLog.append(db, Events.businessChanged, {"keys": write.fields.keys.toList()}, at: now(), permission: Business.viewPermission);
    }

    return write.id;
  }
}

/// The master's one site (`business.md`): mapped at the enrolment to the cloud site it is.
final class SiteEdge extends _ColumnEntity {
  const SiteEdge(this.now);

  final DateTime Function() now;

  @override
  String get name => "site";

  @override
  String get local => "site";

  @override
  String get sqlTable => "site";

  @override
  Map<String, EdgeColumn> get columns => const {
    "name": EdgeColumn("name"), "legalName": EdgeColumn("legal_name"), "taxId": EdgeColumn("tax_id"), "phone": EdgeColumn("phone"),
    "address": EdgeColumn("address"), "landmark": EdgeColumn("landmark"), "city": EdgeColumn("city"), "region": EdgeColumn("region"),
    "postalCode": EdgeColumn("postal_code"), "latitude": EdgeColumn("latitude", EdgeKind.integer),
    "longitude": EdgeColumn("longitude", EdgeKind.integer), "storefront": EdgeColumn("storefront", EdgeKind.boolean),
    "online": EdgeColumn("online", EdgeKind.boolean),
  };

  @override
  List<EdgeTouch> touched(Database db, OplogEntry entry) => switch (entry.kind) {
    "edited" when known(entry.payload.keys).isNotEmpty =>
      [EdgeTouch(name, entry.entityId, EdgeOps.upsert, fields: known(entry.payload.keys))],
    _ => const [],
  };

  @override
  String apply(Database db, EdgeWrite write) {
    if (write.created || write.op != EdgeOps.upsert) throw const EngineFailure("unknown_site");

    final values = sql(write);
    if (values.containsKey("name") && values["name"] == null) EdgeEntity.invalid("name");

    if (values.isNotEmpty) {
      // Both halves of the point or none (B-11): the row would refuse a half anyway.
      final row = db.select("SELECT latitude, longitude FROM site WHERE id = ?", [write.id]).first;
      final latitude = values.containsKey("latitude") ? values["latitude"] : row["latitude"];
      final longitude = values.containsKey("longitude") ? values["longitude"] : row["longitude"];
      if ((latitude == null) != (longitude == null)) EdgeEntity.invalid("latitude");

      update(db, write, values);
      log(db, write, "edited", write.fields);
      EventLog.append(db, Events.businessChanged, {"keys": ["site"]}, at: now(), permission: Business.viewPermission);
    }

    return write.id;
  }
}

// ------------------------------------------------------------------------------ inventory

String _instant(DateTime now) => now.toUtc().toIso8601String();

void _tableChanged(Database db, String table, String what, DateTime now) =>
  EventLog.append(db, Events.tableChanged, {"id": table, "what": what}, at: now, permission: Inventory.viewPermission);

List<String> _fieldsOf(Database db, String table) =>
  [for (final row in db.select("SELECT id FROM inventory_fields WHERE table_id = ? ORDER BY position", [table])) row["id"] as String];

List<String> _recordsOf(Database db, String table) =>
  [for (final row in db.select("SELECT id FROM inventory_records WHERE table_id = ? AND deleted = 0", [table])) row["id"] as String];

/// A product table (`inventory.md`). At most one is `primary`: setting it takes it from the
/// others, on both sides by the same rule.
final class ProductTableEdge extends _ColumnEntity {
  const ProductTableEdge(this.now);

  final DateTime Function() now;

  @override
  String get name => "product_table";

  @override
  String get local => "inventory_table";

  @override
  String get sqlTable => "inventory_tables";

  @override
  Map<String, EdgeColumn> get columns => const {
    "name": EdgeColumn("name"), "description": EdgeColumn("description"), "color": EdgeColumn("color"),
    "primary": EdgeColumn("is_primary", EdgeKind.boolean),
  };

  @override
  Set<String> get required => const {"name", "color"};

  @override
  List<EdgeTouch> touched(Database db, OplogEntry entry) => switch (entry.kind) {
    // A table is made with its fields (a template, an import), which have no entries of their own.
    "created" => [
      EdgeTouch(name, entry.entityId, EdgeOps.upsert),
      for (final field in _fieldsOf(db, entry.entityId)) EdgeTouch("product_field", field, EdgeOps.upsert),
    ],
    "edited" when known(entry.payload.keys).isNotEmpty =>
      [EdgeTouch(name, entry.entityId, EdgeOps.upsert, fields: known(entry.payload.keys))],
    "deleted" => [EdgeTouch(name, entry.entityId, EdgeOps.delete)],
    _ => const [],
  };

  @override
  String apply(Database db, EdgeWrite write) {
    final at = _instant(write.now);

    if (write.op == EdgeOps.delete) {
      if (!write.created) {
        db.execute("UPDATE inventory_tables SET deleted = 1, updated = ?, updated_hlc = ? WHERE id = ?", [at, write.stamp.pack(), write.id]);
        log(db, write, "deleted");
        _tableChanged(db, write.id, "structure", write.now);
      }

      return write.id;
    }

    final values = sql(write);
    if (values["is_primary"] == 1) {
      db.execute("UPDATE inventory_tables SET is_primary = 0 WHERE is_primary = 1 AND id != ?", [write.id]);
    }

    if (write.created) {
      checkRequired(values);
      db.execute(
        "INSERT INTO inventory_tables (id, name, description, color, is_primary, created, updated, created_hlc, updated_hlc) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [write.id, values["name"], values["description"], values["color"], values["is_primary"] ?? 0, at, at,
          write.stamp.pack(), write.stamp.pack()],
      );
      log(db, write, "created", write.fields);
    } else {
      if (values.containsKey("name") && values["name"] == null) EdgeEntity.invalid("name");
      if (values.isEmpty) return write.id;

      update(db, write, {...values, "updated": at});
      log(db, write, "edited", write.fields);
    }

    _tableChanged(db, write.id, "structure", write.now);

    return write.id;
  }
}

/// A product table's field (`inventory.md`). Positions travel as values; what an edit does to the
/// table's other fields or to its products' cells (a move, a new type) travels with it.
final class ProductFieldEdge extends _ColumnEntity {
  const ProductFieldEdge(this.now);

  final DateTime Function() now;

  @override
  String get name => "product_field";

  @override
  String get local => "inventory_field";

  @override
  String get sqlTable => "inventory_fields";

  @override
  bool get softDelete => false;

  @override
  Map<String, String> get refs => const {"table": "product_table"};

  @override
  Map<String, EdgeColumn> get columns => const {
    "table": EdgeColumn("table_id"), "name": EdgeColumn("name"), "description": EdgeColumn("description"),
    "type": EdgeColumn("type"), "position": EdgeColumn("position", EdgeKind.integer), "width": EdgeColumn("width", EdgeKind.integer),
    "options": EdgeColumn("options", EdgeKind.json), "unit": EdgeColumn("unit"), "visibility": EdgeColumn("visibility"),
    "summary": EdgeColumn("summary", EdgeKind.boolean),
  };

  @override
  Set<String> get required => const {"table", "name", "type", "position"};

  @override
  List<EdgeTouch> touched(Database db, OplogEntry entry) {
    final table = entry.payload["table"] as String? ??
      db.select("SELECT table_id FROM inventory_fields WHERE id = ?", [entry.entityId]).firstOrNull?["table_id"] as String?;
    if (table == null) return const [];

    final fields = known(entry.payload.keys);
    final moved = entry.kind != "edited" || fields.contains("position");
    final type = db.select("SELECT type FROM inventory_fields WHERE id = ?", [entry.entityId]).firstOrNull?["type"];
    final recast = (entry.kind == "edited" && fields.contains("type")) || (entry.kind == "created" && type == FieldTypes.counter);

    return [
      switch (entry.kind) {
        "created" => EdgeTouch(name, entry.entityId, EdgeOps.upsert),
        "deleted" => EdgeTouch(name, entry.entityId, EdgeOps.delete),
        _ => EdgeTouch(name, entry.entityId, EdgeOps.upsert, fields: fields),
      },
      if (moved)
        for (final sibling in _fieldsOf(db, table))
          if (sibling != entry.entityId) EdgeTouch(name, sibling, EdgeOps.upsert, fields: const {"position"}),
      if (recast)
        for (final record in _recordsOf(db, table)) EdgeTouch("product", record, EdgeOps.upsert, cells: {entry.entityId}),
    ];
  }

  @override
  String apply(Database db, EdgeWrite write) {
    final at = _instant(write.now);
    final current = db.select("SELECT table_id FROM inventory_fields WHERE id = ?", [write.id]).firstOrNull;

    if (write.op == EdgeOps.delete) {
      if (current != null) {
        final table = current["table_id"] as String;
        db.execute("DELETE FROM inventory_fields WHERE id = ?", [write.id]);
        db.execute("UPDATE inventory_records SET data = json_remove(data, ?) WHERE table_id = ?", ['\$."${write.id}"', table]);
        log(db, write, "deleted", {"table": table});
        _tableChanged(db, table, "structure", write.now);
      }

      return write.id;
    }

    final values = sql(write);

    if (write.created) {
      checkRequired(values);
      final table = values["table_id"] as String;
      if (db.select("SELECT 1 FROM inventory_tables WHERE id = ?", [table]).isEmpty) throw const EngineFailure("unknown_reference");

      db.execute(
        "INSERT INTO inventory_fields (id, table_id, name, description, type, position, width, options, unit, visibility, "
        "summary, created, updated, created_hlc, updated_hlc) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [write.id, table, values["name"], values["description"], values["type"], values["position"], values["width"],
          values["options"] ?? "[]", values["unit"] ?? "", values["visibility"] ?? "visible", values["summary"] ?? 0,
          at, at, write.stamp.pack(), write.stamp.pack()],
      );
      log(db, write, "created", write.fields);
      _tableChanged(db, table, "structure", write.now);

      return write.id;
    }

    if (current == null) throw const EngineFailure(ErrorCodes.notFound);
    for (final field in required) {
      if (values.containsKey(columns[field]!.name) && values[columns[field]!.name] == null) EdgeEntity.invalid(field);
    }
    // A field doesn't move to another table.
    values.remove("table_id");
    if (values.isEmpty) return write.id;

    update(db, write, {...values, "updated": at});
    log(db, write, "edited", write.fields);
    _tableChanged(db, current["table_id"] as String, "structure", write.now);

    return write.id;
  }
}

/// A product: a record of a product table (`inventory.md`), its values one cell per field. Image
/// cells name files, which don't travel yet (`task-edge-sync-backend.md` §11).
final class ProductEdge extends EdgeEntity {
  const ProductEdge(this.now);

  final DateTime Function() now;

  @override
  String get name => "product";

  @override
  String get local => "inventory_record";

  @override
  Map<String, String> get refs => const {"table": "product_table"};

  @override
  String get cellsOf => "product_field";

  Set<String> _images(Database db, String table) => {
    for (final row in db.select("SELECT id FROM inventory_fields WHERE table_id = ? AND type = ?", [table, FieldTypes.image]))
      row["id"] as String,
  };

  @override
  List<String> ids(Database db) =>
    [for (final row in db.select("SELECT id FROM inventory_records WHERE deleted = 0")) row["id"] as String];

  @override
  EdgeRow? read(Database db, String id) {
    final row = db.select("SELECT table_id, data, updated_hlc, deleted FROM inventory_records WHERE id = ?", [id]).firstOrNull;
    if (row == null) return null;

    final table = row["table_id"] as String;
    final images = _images(db, table);
    final data = jsonDecode(row["data"] as String) as Map<String, Object?>;

    return EdgeRow(
      fields: {"table": table},
      cells: {for (final entry in data.entries) if (!images.contains(entry.key)) entry.key: entry.value},
      hlc: Hlc.parse(row["updated_hlc"] as String),
      deleted: row["deleted"] == 1,
    );
  }

  @override
  List<EdgeTouch> touched(Database db, OplogEntry entry) {
    final table = entry.payload["table"] as String?;

    return switch (entry.kind) {
      "created" => [EdgeTouch(name, entry.entityId, EdgeOps.upsert)],
      "deleted" => [EdgeTouch(name, entry.entityId, EdgeOps.delete)],
      "edited" => switch (entry.payload["data"]) {
        final Map<String, Object?> data when table != null => [
          if (data.keys.toSet().difference(_images(db, table)) case final cells when cells.isNotEmpty)
            EdgeTouch(name, entry.entityId, EdgeOps.upsert, cells: cells),
        ],
        _ => const [],
      },
      _ => const [],
    };
  }

  @override
  String apply(Database db, EdgeWrite write) {
    final at = _instant(write.now);

    if (write.op == EdgeOps.delete) {
      final row = db.select("SELECT table_id FROM inventory_records WHERE id = ?", [write.id]).firstOrNull;
      if (row != null) {
        db.execute("UPDATE inventory_records SET deleted = 1, updated = ?, updated_hlc = ? WHERE id = ?", [at, write.stamp.pack(), write.id]);
        log(db, write, "deleted", {"table": row["table_id"]});
        _recordWritten(db, row["table_id"] as String, write);
      }

      return write.id;
    }

    if (write.created) {
      final table = write.fields["table"];
      if (table is! String) EdgeEntity.invalid("table");
      if (db.select("SELECT 1 FROM inventory_tables WHERE id = ?", [table]).isEmpty) throw const EngineFailure("unknown_reference");

      final cells = {for (final entry in write.cells.entries) if (entry.value != null) entry.key: entry.value};
      db.execute(
        "INSERT INTO inventory_records (id, table_id, data, created, updated, created_hlc, updated_hlc) VALUES (?, ?, ?, ?, ?, ?, ?)",
        [write.id, table, jsonEncode(cells), at, at, write.stamp.pack(), write.stamp.pack()],
      );
      log(db, write, "created", {"table": table, "data": cells});
      _recordWritten(db, table, write);

      return write.id;
    }

    final row = db.select("SELECT table_id, data, deleted FROM inventory_records WHERE id = ?", [write.id]).firstOrNull;
    if (row == null) throw const EngineFailure(ErrorCodes.notFound);
    if (write.cells.isEmpty) return write.id;

    final table = row["table_id"] as String;
    final data = jsonDecode(row["data"] as String) as Map<String, Object?>;
    for (final MapEntry(key: field, value: value) in write.cells.entries) {
      value == null ? data.remove(field) : data[field] = value;
    }

    // An edit newer than the delete brings the product back (§9.3).
    db.execute("UPDATE inventory_records SET data = ?, deleted = 0, updated = ?, updated_hlc = ? WHERE id = ?",
      [jsonEncode(data), at, write.stamp.pack(), write.id]);
    log(db, write, "edited", {"table": table, "data": write.cells});
    _recordWritten(db, table, write);

    return write.id;
  }

  void _recordWritten(Database db, String table, EdgeWrite write) {
    db.execute("UPDATE inventory_tables SET last_record = ?, updated_hlc = ? WHERE id = ?", [_instant(write.now), write.stamp.pack(), table]);
    _tableChanged(db, table, "records", write.now);
  }
}

/// A stock movement (`stock.md`): a fact. One the cloud made is written by the ledger itself,
/// like a replayed outbox's: never refused for the balance, flagged when it goes negative.
final class StockMovementEdge extends EdgeEntity {
  const StockMovementEdge(this.stock);

  final Stock stock;

  @override
  String get name => "stock_movement";

  @override
  String get local => "stock_movement";

  @override
  bool get fact => true;

  @override
  Map<String, String> get refs => const {"product": "product", "table": "product_table"};

  @override
  List<String> ids(Database db) => [for (final row in db.select("SELECT id FROM stock_movements ORDER BY hlc")) row["id"] as String];

  @override
  EdgeRow? read(Database db, String id) {
    final row = db.select("SELECT * FROM stock_movements WHERE id = ?", [id]).firstOrNull;
    if (row == null) return null;

    return EdgeRow(fields: {
      "product": row["product_id"], "table": row["table_id"], "operation": row["operation"], "reason": row["reason"],
      "quantity": row["quantity"], "note": row["note"], "source": row["source"], "at": row["at"],
    }, hlc: Hlc.parse(row["hlc"] as String));
  }

  @override
  List<EdgeTouch> touched(Database db, OplogEntry entry) =>
    entry.kind == "created" ? [EdgeTouch(name, entry.entityId, EdgeOps.append)] : const [];

  @override
  String apply(Database db, EdgeWrite write) {
    if (write.op != EdgeOps.append) throw const EngineFailure("unsupported_op");

    final fields = write.fields;
    final product = fields["product"], table = fields["table"], operation = fields["operation"];
    if (product is! String) EdgeEntity.invalid("product");
    if (table is! String) EdgeEntity.invalid("table");
    if (operation is! String) EdgeEntity.invalid("operation");

    stock.move(
      operation: operation,
      tableId: table,
      productId: product,
      quantity: fields["quantity"],
      reason: fields["reason"],
      note: fields["note"],
      source: Stock.cloudSource,
      device: edgeOrigin,
      commandId: write.commandId,
    );

    return db.select("SELECT id FROM stock_movements WHERE command_id = ?", [write.commandId]).first["id"] as String;
  }
}

/// A payment (`money.md`): a fact, voided by a later one. The account it was paid into is sealed
/// and doesn't travel yet; a ticket arrives with the POS's version.
final class PaymentEdge extends EdgeEntity {
  const PaymentEdge();

  @override
  String get name => "payment";

  @override
  String get local => "money_payment";

  @override
  bool get fact => true;

  static const _fields = ["concept", "direction", "amount", "currency", "method", "reference", "note", "date"];

  @override
  List<String> ids(Database db) => [for (final row in db.select("SELECT id FROM money_payments ORDER BY created_hlc")) row["id"] as String];

  @override
  EdgeRow? read(Database db, String id) {
    final row = db.select("SELECT * FROM money_payments WHERE id = ?", [id]).firstOrNull;
    if (row == null) return null;

    final counterpart = row["counterpart"] as String?;

    return EdgeRow(
      fields: {
        for (final field in _fields) field: row[field],
        "counterpart": counterpart == null ? null : jsonDecode(counterpart),
        "at": row["created"],
      },
      hlc: Hlc.parse(row["created_hlc"] as String),
      voided: row["status"] == "voided"
        ? ({"reason": row["void_reason"], "at": row["voided_at"]}, Hlc.parse(row["updated_hlc"] as String))
        : null,
    );
  }

  @override
  List<EdgeTouch> touched(Database db, OplogEntry entry) => switch (entry.kind) {
    "recorded" => [EdgeTouch(name, entry.entityId, EdgeOps.append)],
    "voided" => [EdgeTouch(name, entry.entityId, EdgeOps.voided)],
    _ => const [],
  };

  @override
  String apply(Database db, EdgeWrite write) {
    final fields = write.fields;

    if (write.op == EdgeOps.voided) {
      if (write.created) throw const EngineFailure("unknown_reference");

      db.execute(
        "UPDATE money_payments SET status = 'voided', void_reason = ?, voided_by = ?, voided_at = ?, updated_hlc = ? "
        "WHERE id = ? AND status = 'recorded'",
        [fields["reason"], _account(db, write.actor), fields["at"] ?? _instant(write.now), write.stamp.pack(), write.id],
      );
      log(db, write, "voided");

      return write.id;
    }

    if (write.op != EdgeOps.append) throw const EngineFailure("unsupported_op");

    final amount = fields["amount"];
    if (amount is! int || amount <= 0) EdgeEntity.invalid("amount");
    for (final field in const ["concept", "direction", "currency", "method", "date"]) {
      if (fields[field] is! String) EdgeEntity.invalid(field);
    }

    final counterpart = fields["counterpart"];
    db.execute(
      "INSERT INTO money_payments (id, concept, direction, amount, currency, method, reference, counterpart, note, date, "
      "registered_by, device, created, created_hlc, updated_hlc) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [write.id, fields["concept"], fields["direction"], amount, fields["currency"], fields["method"], fields["reference"],
        counterpart == null ? null : jsonEncode(counterpart), fields["note"], fields["date"],
        _account(db, write.actor) ?? edgeOrigin, edgeOrigin, fields["at"] ?? _instant(write.now),
        write.stamp.pack(), write.stamp.pack()],
    );
    log(db, write, "recorded", {"concept": fields["concept"], "amount": amount});

    return write.id;
  }

  /// The local account of the person who did it in the cloud, by e-mail.
  static String? _account(Database db, String? email) => email == null
    ? null
    : db.select("SELECT id FROM accounts WHERE lower(email) = lower(?)", [email]).firstOrNull?["id"] as String?;
}

/// An exchange currency (`money.md` M-50 to M-53): one record per code, the code its id on both
/// sides.
final class CurrencyEdge extends _ColumnEntity {
  const CurrencyEdge();

  @override
  String get name => "currency";

  @override
  String get local => "money_currency";

  @override
  bool get natural => true;

  @override
  String get sqlTable => "money_currencies";

  @override
  String get key => "currency";

  @override
  bool get softDelete => false;

  @override
  Map<String, EdgeColumn> get columns => const {
    "mode": EdgeColumn("mode"), "custom": EdgeColumn("custom", EdgeKind.real), "active": EdgeColumn("active", EdgeKind.boolean),
  };

  @override
  List<EdgeTouch> touched(Database db, OplogEntry entry) => switch (entry.kind) {
    "saved" => [EdgeTouch(name, entry.entityId, EdgeOps.upsert, fields: {"mode", "custom", "active"})],
    "removed" => [EdgeTouch(name, entry.entityId, EdgeOps.upsert, fields: const {"active"})],
    _ => const [],
  };

  @override
  String apply(Database db, EdgeWrite write) {
    if (write.op != EdgeOps.upsert) throw const EngineFailure("unsupported_op");
    if (!RegExp(r"^[A-Z]{3}$").hasMatch(write.id)) EdgeEntity.invalid("currency");

    final values = sql(write);
    if (values.containsKey("mode") && values["mode"] != "official" && values["mode"] != "custom") EdgeEntity.invalid("mode");

    if (write.created) {
      if (values["mode"] == null) EdgeEntity.invalid("mode");
      db.execute(
        "INSERT INTO money_currencies (currency, mode, custom, active, updated_hlc) VALUES (?, ?, ?, ?, ?)",
        [write.id, values["mode"], values["custom"], values["active"] ?? 1, write.stamp.pack()],
      );
    } else if (values.isNotEmpty) {
      update(db, write, values);
    } else {
      return write.id;
    }

    log(db, write, "saved", write.fields);

    return write.id;
  }
}

// ----------------------------------------------------------------------------- deliveries

/// A delivery option or area (`deliveries.md`): one row per record, removed by `deleted`.
abstract base class _DeliveryEdge extends _ColumnEntity {
  const _DeliveryEdge();

  /// The fields a record made here from the cloud must have.
  @override
  Set<String> get required;

  @override
  List<EdgeTouch> touched(Database db, OplogEntry entry) => switch (entry.kind) {
    "created" => [EdgeTouch(name, entry.entityId, EdgeOps.upsert)],
    "edited" when known(entry.payload.keys).isNotEmpty =>
      [EdgeTouch(name, entry.entityId, EdgeOps.upsert, fields: known(entry.payload.keys))],
    "removed" => [EdgeTouch(name, entry.entityId, EdgeOps.delete)],
    _ => const [],
  };

  @override
  String apply(Database db, EdgeWrite write) {
    if (write.op == EdgeOps.delete) {
      if (!write.created) {
        db.execute("UPDATE $sqlTable SET deleted = 1, updated_hlc = ? WHERE id = ?", [write.stamp.pack(), write.id]);
        log(db, write, "removed");
      }

      return write.id;
    }

    final values = sql(write);
    for (final field in required) {
      if (values.containsKey(columns[field]!.name) && values[columns[field]!.name] == null) EdgeEntity.invalid(field);
    }

    if (write.created) {
      checkRequired(values);
      final row = {
        "id": write.id,
        ...values,
        "created": _instant(write.now),
        "created_hlc": write.stamp.pack(),
        "updated_hlc": write.stamp.pack(),
      };
      db.execute(
        "INSERT INTO $sqlTable (${row.keys.join(", ")}) VALUES (${row.keys.map((_) => "?").join(", ")})",
        row.values.toList(),
      );
      log(db, write, "created", write.fields);
    } else {
      // An upsert newer than a delete brings the record back (§5).
      final restored = db.select("SELECT deleted FROM $sqlTable WHERE id = ?", [write.id]).firstOrNull?["deleted"] == 1;
      if (values.isEmpty && !restored) return write.id;

      update(db, write, {...values, if (restored) "deleted": 0});
      log(db, write, "edited", write.fields);
    }

    return write.id;
  }
}

/// A way the company delivers: `zones` as `[{name, fee}]`, money in minor units, `radius` in metres.
final class DeliveryOptionEdge extends _DeliveryEdge {
  const DeliveryOptionEdge();

  @override
  String get name => "delivery_option";

  @override
  String get local => "delivery_option";

  @override
  String get sqlTable => "delivery_options";

  @override
  Map<String, EdgeColumn> get columns => const {
    "mode": EdgeColumn("mode"), "provider": EdgeColumn("provider"), "label": EdgeColumn("label"),
    "coverage": EdgeColumn("coverage"), "radius": EdgeColumn("radius", EdgeKind.integer),
    "zones": EdgeColumn("zones", EdgeKind.json), "fee": EdgeColumn("fee", EdgeKind.integer),
    "freeFrom": EdgeColumn("free_from", EdgeKind.integer), "etaMin": EdgeColumn("eta_min", EdgeKind.integer),
    "etaMax": EdgeColumn("eta_max", EdgeKind.integer), "notes": EdgeColumn("notes"),
    "position": EdgeColumn("position", EdgeKind.integer),
  };

  @override
  Set<String> get required => const {"mode", "coverage", "position"};
}

/// An area drawn on the map: a point in millionths of a degree, `polygon` as `[[latitude,
/// longitude]]` in millionths, `radius` in metres.
final class DeliveryAreaEdge extends _DeliveryEdge {
  const DeliveryAreaEdge();

  @override
  String get name => "delivery_area";

  @override
  String get local => "delivery_area";

  @override
  String get sqlTable => "delivery_areas";

  @override
  Map<String, EdgeColumn> get columns => const {
    "name": EdgeColumn("name"), "kind": EdgeColumn("kind"), "latitude": EdgeColumn("latitude", EdgeKind.integer),
    "longitude": EdgeColumn("longitude", EdgeKind.integer), "radius": EdgeColumn("radius", EdgeKind.integer),
    "polygon": EdgeColumn("polygon", EdgeKind.json), "fee": EdgeColumn("fee", EdgeKind.integer),
    "minimum": EdgeColumn("minimum", EdgeKind.integer), "active": EdgeColumn("active", EdgeKind.boolean),
    "position": EdgeColumn("position", EdgeKind.integer),
  };

  @override
  Set<String> get required => const {"name", "kind", "active", "position"};
}

/// The master's people, sent once at the first link so the cloud makes their accounts (D10). They
/// never come back: who may do what is the cloud's word, and doesn't travel in this version.
final class AccountEdge extends EdgeEntity {
  const AccountEdge();

  @override
  String get name => "account";

  @override
  String get local => "account";

  @override
  List<String> ids(Database db) => [
    for (final row in db.select("SELECT id FROM accounts WHERE status = 'active' AND email IS NOT NULL AND deleted = 0")) row["id"] as String,
  ];

  /// With the person's permissions here (`permissions`): the cloud admits a new account with
  /// them (§10); from then on the cloud's are the ones that count (`member`).
  @override
  EdgeRow? read(Database db, String id) {
    final row = db.select("SELECT email, first_name, last_name, updated_hlc FROM accounts WHERE id = ?", [id]).firstOrNull;
    if (row == null) return null;

    final member = Grants.read(db, id);
    final all = id == Grants.owner(db) || (member?.all ?? false);

    return EdgeRow(
      fields: {
        "email": row["email"],
        "firstName": row["first_name"],
        "lastName": row["last_name"],
        "permissions": {
          "access": id == Grants.owner(db) || (member?.access ?? false),
          "all": all,
          "sections": all ? const <String, Object?>{} : PermissionCatalog.normalize(member?.sections),
          "template": member?.template == null ? null : {"scope": member!.template!.scope, "id": member.template!.id},
        },
      },
      hlc: Hlc.parse(row["updated_hlc"] as String),
    );
  }

  @override
  bool get pulls => false;

  @override
  List<EdgeTouch> touched(Database db, OplogEntry entry) => const [];

  @override
  String apply(Database db, EdgeWrite write) => write.id;
}

/// A person's permissions as the cloud holds them (`session.md` P-12): pulled, never pushed. Who
/// may do what is the cloud's word while the master syncs (plan §9.3), so nothing written here
/// goes up, and the master refuses to change permissions meanwhile (`permissions_online`).
///
/// Its id is the cloud account's, the same as the `account` entity's, so it is natural: the
/// document is kept under that id (`sync_members`) and laid onto the local account it names,
/// found through the accounts' id map or by e-mail. One whose person has no account here yet waits
/// there for when they are admitted (`Grants.admit`).
final class MemberEdge extends EdgeEntity {
  const MemberEdge(this.now, this.changed);

  final DateTime Function() now;

  /// Told every account whose permissions a pull wrote, so its open sessions take them (P-8).
  final void Function(String account) changed;

  @override
  String get name => "member";

  @override
  String get local => "member";

  @override
  bool get natural => true;

  /// Never uploaded: the people go up as `account`, with their permissions.
  @override
  List<String> ids(Database db) => const [];

  @override
  EdgeRow? read(Database db, String id) {
    final row = db.select("SELECT * FROM sync_members WHERE cloud_id = ?", [id]).firstOrNull;
    if (row == null) return null;

    final sections = row["sections"] as String?;
    final template = row["template"] as String?;

    return EdgeRow(
      fields: {
        "email": row["email"],
        "access": row["access"] == 1,
        "all": row["all_granted"] == 1,
        "sections": sections == null ? null : jsonDecode(sections),
        "template": template == null ? null : jsonDecode(template),
        "custom": row["custom"] == 1,
      },
      hlc: Hlc.parse(row["updated_hlc"] as String),
    );
  }

  @override
  List<EdgeTouch> touched(Database db, OplogEntry entry) => const [];

  @override
  String apply(Database db, EdgeWrite write) {
    if (write.op != EdgeOps.upsert && write.op != EdgeOps.delete) throw const EngineFailure("invalid");

    final document = {
      "email": null, "access": false, "all": false, "sections": null, "template": null, "custom": false,
      ...?read(db, write.id)?.fields,
      ...write.fields,
      // The cloud took the person out of the company: no access, the document kept (P-5).
      if (write.op == EdgeOps.delete) "access": false,
    };

    final email = document["email"];
    if (email != null && email is! String) EdgeEntity.invalid("email");
    for (final flag in const ["access", "all", "custom"]) {
      if (document[flag] is! bool) EdgeEntity.invalid(flag);
    }
    final sections = document["sections"];
    if (sections != null && sections is! Map) EdgeEntity.invalid("sections");
    final template = document["template"];
    if (template != null &&
        (template is! Map || !const {"global", "company"}.contains(template["scope"]) || template["id"] is! String)) {
      EdgeEntity.invalid("template");
    }

    db.execute(
      "INSERT INTO sync_members (cloud_id, email, access, all_granted, sections, template, custom, updated_hlc) "
      "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8) ON CONFLICT (cloud_id) DO UPDATE SET email = ?2, access = ?3, "
      "all_granted = ?4, sections = ?5, template = ?6, custom = ?7, updated_hlc = ?8",
      [
        write.id,
        email,
        document["access"] == true ? 1 : 0,
        document["all"] == true ? 1 : 0,
        // A key a newer catalog has and this engine doesn't is dropped, not refused: the cloud's
        // word stands for what this engine knows.
        sections == null ? null : jsonEncode(PermissionCatalog.normalize(sections)),
        template == null ? null : jsonEncode({"scope": (template as Map)["scope"], "id": template["id"]}),
        document["custom"] == true ? 1 : 0,
        write.stamp.pack(),
      ],
    );
    log(db, write, write.created ? "created" : "edited", write.fields);

    final account = _account(db, write.id, email as String?);
    if (account != null) {
      Grants.fromCloud(db, account, now: now());
      EventLog.append(db, Events.permissionsChanged, {"accountId": account}, at: now(), accounts: [account]);
      AuditLog(db, now: now).append(
        document["access"] == true ? AuditKinds.permissionsAssigned : AuditKinds.permissionsRevoked,
        actor: null,
        device: edgeOrigin,
        data: {"account": account, "all": document["all"], "template": document["template"], "from": "cloud", "by": write.actor},
      );
      changed(account);
    }

    return write.id;
  }

  static String? _account(Database db, String cloudId, String? email) =>
    db.select("SELECT local_id FROM sync_ids WHERE entity = 'account' AND cloud_id = ?", [cloudId]).firstOrNull?["local_id"]
      as String? ??
    (email == null
      ? null
      : db.select("SELECT id FROM accounts WHERE lower(email) = lower(?) AND deleted = 0", [email]).firstOrNull?["id"] as String?);
}
