part of 'inventory.dart';

/// A spreadsheet into a table (`inventory.md` I-40 to I-47), in the two steps the app already
/// makes against the cloud: the structure (a table from the header row), then the records.
///
/// The cloud types the columns with a model in the background, half a minute; here the rules
/// ([Typing]) take milliseconds, so the structure step types them before it answers. Its events
/// still bracket the typing (`table/normalizing`, then `table/ready`), so the app's wait reads
/// both modes the same way.
extension InventoryImport on Inventory {
  /// `inventory.import.structure`: the table, its columns typed (I-42 to I-45), and an image
  /// column when the file has none. Answers `{id}`.
  Map<String, Object?> importStructure(Sheet sheet, {String? name, String? actor, String? device}) {
    final id = newId();

    _store.write((db) {
      final language = _language(db);
      final title = (name == null || name.trim().isEmpty) ? TableTemplates.name(TableTemplates.imported, language) : name.trim();
      final stamp = _clock.tick();
      final primary = db.select("SELECT 1 FROM inventory_tables WHERE deleted = 0 AND is_primary = 1").isEmpty;

      db.execute(
        "INSERT INTO inventory_tables (id, name, color, is_primary, import_stage, created, updated, created_hlc, updated_hlc) "
        "VALUES (?, ?, ?, ?, 'preparing', ?, ?, ?, ?)",
        [id, title.length > 80 ? title.substring(0, 80).trim() : title, _importColor, primary ? 1 : 0, _stamp, _stamp,
          stamp.pack(), stamp.pack()],
      );

      final fields = [
        for (final (position, header) in sheet.headers.indexed)
          _insertField(db, stamp, id, name: header, type: FieldTypes.text, position: position, handTyped: false),
      ];
      EventLog.append(db, Events.tableNormalizing, {"id": id, "normalize": true, "ai": false}, at: _now(), permission: Inventory.viewPermission);

      final types = Typing.columns(sheet.headers, [
        for (var column = 0; column < sheet.headers.length; column++)
          [for (final row in sheet.rows.take(Typing.sample)) row[column]],
      ], language: language);
      var summarized = 0;

      for (final (index, type) in types.indexed) {
        final summary = _summarized.contains(type);
        if (type == FieldTypes.text) continue;
        if (summary) summarized++;

        db.execute("UPDATE inventory_fields SET type = ?, summary = ? WHERE id = ?", [type, summary ? 1 : 0, fields[index]]);
      }

      var image = types.contains(FieldTypes.image) ? fields[types.indexOf(FieldTypes.image)] : null;
      image ??= _insertField(db, stamp, id,
        name: Sheet.names([...sheet.headers, TableTemplates.name(TableTemplates.photos, language)]).last,
        type: FieldTypes.image,
        position: fields.length,
        handTyped: false,
      );

      db.execute("UPDATE inventory_tables SET import_stage = 'loading' WHERE id = ?", [id]);
      Oplog(db).append(hlc: stamp, entity: "inventory_table", entityId: id, kind: "created", payload: {
        "name": title,
        "import": true,
        "primary": primary,
        "fields": [for (final field in _fields(id)) [field["id"], field["name"], field["type"]]],
      }, actor: actor, device: device);
      EventLog.append(db, Events.tableReady, {
        "id": id,
        "ok": true,
        "normalized": true,
        "retyped": types.where((type) => type != FieldTypes.text).length,
        "narrowed": 0,
        "renamed": 0,
        "summarized": summarized,
        "image": image,
      }, at: _now(), permission: Inventory.viewPermission);
      _tableChanged(db, id, "structure");
    });

    return {"id": id};
  }

  /// `inventory.import.records`: [sheet]'s rows into [tableId], each column matched to the
  /// field of its name (I-45, I-46). A cell that doesn't fit its column is kept as text; a stock
  /// column's numbers come back as opening balances for the ledger (I-44), never as cells.
  ({int imported, int withInvalidCells, List<(String, int)> opening}) importRecords(
    String tableId,
    Sheet sheet, {
    required int decimals,
    String? actor,
    String? device,
  }) => _store.write((db) {
    final table = _table(tableId);
    final language = _language(db);
    final byName = {for (final field in _fields(tableId)) fold((field["name"] as String).trim()): field};
    final columns = [for (final header in sheet.headers) byName[fold(header.trim())]];
    final counters = _fields(tableId).where((field) => field["type"] == FieldTypes.counter).toList();
    final skus = <String>{
      for (final field in byName.values.where((field) => field["type"] == FieldTypes.sku))
        for (final row in db.select(
          "SELECT json_extract(data, ?) AS sku FROM inventory_records WHERE table_id = ? AND deleted = 0",
          [Inventory._path(field["id"] as String), tableId],
        ))
          if (row["sku"] != null) fold("${row["sku"]}".trim()),
    };
    var next = table["next_counter"] as int;
    var imported = 0;
    var invalid = 0;
    final opening = <(String, int)>[];

    for (final row in sheet.rows) {
      final cells = <String, Object?>{};
      var units = 0;
      var broken = false;

      for (final (index, field) in columns.indexed) {
        final raw = row[index].trim();
        if (field == null || raw.isEmpty) continue;

        final fieldId = field["id"] as String;
        final type = field["type"] as String;

        switch (type) {
          case FieldTypes.counter:
            continue;
          case FieldTypes.stock:
            final count = Typing.units(raw, language: language);
            if (count == null) broken = true;
            units = count ?? 0;
          case FieldTypes.image:
            final images = Typing.cell(type, raw, language: language);
            if (images == null) broken = true;
            if (images != null) cells[fieldId] = images;
          case FieldTypes.sku:
            final key = fold(raw);
            if (!skus.add(key)) {
              broken = true;
              continue;
            }
            cells[fieldId] = Typing.cell(type, raw, language: language) ?? raw;
          default:
            final value = Typing.cell(type, raw, language: language, decimals: _places(field, decimals));
            if (value == null) broken = true;
            cells[fieldId] = value ?? raw;
        }
      }

      if (cells.isEmpty && units == 0) continue;

      for (final field in counters) {
        cells[field["id"] as String] = next++;
      }

      final id = newId();
      final stamp = _clock.tick();

      db.execute(
        "INSERT INTO inventory_records (id, table_id, data, created, updated, created_by, updated_by, created_hlc, updated_hlc) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [id, tableId, jsonEncode(cells), _stamp, _stamp, actor, actor, stamp.pack(), stamp.pack()],
      );
      Oplog(db).append(hlc: stamp, entity: "inventory_record", entityId: id, kind: "created",
        payload: {"table": tableId, "data": cells, "import": true}, actor: actor, device: device);

      if (units > 0) opening.add((id, units));
      imported++;
      if (broken) invalid++;
    }

    final stamp = _clock.tick();
    db.execute(
      "UPDATE inventory_tables SET next_counter = ?, import_stage = NULL, last_record = coalesce(?, last_record), updated_hlc = ? WHERE id = ?",
      [next, imported > 0 ? _stamp : null, stamp.pack(), tableId],
    );
    _tableChanged(db, tableId, "records");

    return (imported: imported, withInvalidCells: invalid, opening: opening);
  });

  /// `inventory.tables.normalize {tableId}` (I-47): the rules again, over the stored values,
  /// for the fields nobody typed by hand. A rule never makes a stock or counter column here
  /// (their values aren't cells), nor a second title. Answers `TableNormalizeModel`.
  Map<String, Object?> normalize(String tableId, {required int decimals, String? actor, String? device}) => _store.write((db) {
    _table(tableId);
    final language = _language(db);
    final fields = _fields(tableId);
    final open = [
      for (final field in fields)
        if (field["hand_typed"] == 0 && !FieldTypes.readOnly.contains(field["type"])) field,
    ];
    final sample = [
      for (final row in db.select(
        "SELECT data FROM inventory_records WHERE table_id = ? AND deleted = 0 ORDER BY id LIMIT ?",
        [tableId, Typing.sample],
      ))
        jsonDecode(row["data"] as String) as Map<String, Object?>,
    ];
    final types = Typing.columns(
      [for (final field in open) field["name"] as String],
      [for (final field in open) [for (final data in sample) Cells.asText(data[field["id"]])]],
      language: language,
    );
    final titled = fields.any((field) => field["type"] == FieldTypes.title && !open.contains(field));
    var retyped = 0;
    var summarized = 0;
    var recast = 0;

    for (final (index, field) in open.indexed) {
      final from = field["type"] as String;
      var to = types[index];
      if (FieldTypes.readOnly.contains(to) || to == FieldTypes.title && titled) to = FieldTypes.text;
      if (to == from) continue;

      final fieldId = field["id"] as String;
      final summary = _summarized.contains(to) && field["summary"] != 1;
      final stamp = _clock.tick();

      db.execute("UPDATE inventory_fields SET type = ?, summary = ?, updated = ?, updated_hlc = ? WHERE id = ?",
        [to, summary ? 1 : field["summary"], _stamp, stamp.pack(), fieldId]);
      if (_recast(db, tableId, field, to, language: language, decimals: decimals)) recast++;
      Oplog(db).append(hlc: stamp, entity: "inventory_field", entityId: fieldId, kind: "edited",
        payload: {"type": to, if (summary) "summary": 1, "rules": true}, actor: actor, device: device);

      retyped++;
      if (summary) summarized++;
    }

    if (retyped > 0) {
      _touchTable(db, _clock.tick(), tableId);
      _tableChanged(db, tableId, "records");
    }

    return {
      "id": tableId,
      "retyped": retyped,
      "narrowed": 0,
      "renamed": 0,
      "summarized": summarized,
      "recast": recast,
      "reindexed": false,
      "image": fields.where((field) => field["type"] == FieldTypes.image).firstOrNull?["id"] ?? "",
    };
  });

  /// [field]'s stored values read again as [type], by the import's rules (a `$1.500,50` is a
  /// price); one that doesn't fit stays as its text (I-14). Whether any value was rewritten.
  bool _recast(Database db, String tableId, Row field, String type, {required String language, required int decimals}) {
    final path = Inventory._path(field["id"] as String);
    var any = false;

    for (final row in db.select(
      "SELECT id, data FROM inventory_records WHERE table_id = ? AND json_type(data, ?) IS NOT NULL",
      [tableId, path],
    )) {
      final text = Cells.asText((jsonDecode(row["data"] as String) as Map)[field["id"]]);
      final value = Typing.cell(type, text, language: language, decimals: _places(field, decimals)) ??
        (type == FieldTypes.image ? null : text);

      db.execute(
        value == null ? "UPDATE inventory_records SET data = json_remove(data, ?) WHERE id = ?" : "UPDATE inventory_records SET data = json_set(data, ?, json(?)) WHERE id = ?",
        [path, if (value != null) jsonEncode(value), row["id"]],
      );
      any = true;
    }

    return any;
  }

  /// How many decimals a price of [field] takes: its currency's, else the company's.
  static int _places(Row field, int decimals) {
    final unit = field["unit"] as String;

    return FieldTypes.withUnit.contains(field["type"]) && Catalogs.hasCurrency(unit)
      ? Catalogs.currencyRows.firstWhere((row) => row["code"] == unit)["decimals"] as int
      : decimals;
  }

  static String _language(Database db) => db.select("SELECT language FROM company").firstOrNull?["language"] as String? ?? "en";

  /// The fields a person sees at a glance in the stock summary (I-43.4).
  static const _summarized = {FieldTypes.title, FieldTypes.sku, FieldTypes.price};

  static const _importColor = "0xFF60A5FA";
}
