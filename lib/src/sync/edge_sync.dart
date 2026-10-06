import 'dart:convert';
import 'dart:typed_data';

import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../crypto/envelope.dart';
import '../failure.dart';
import '../ids.dart';
import '../oplog/hlc.dart';
import '../oplog/oplog.dart';
import '../storage/store.dart';
import 'edge.dart';
import 'entities.dart';

/// Where a linked master's sync stands (`sync_link.phase`): the cloud's state to download first,
/// then the master's own to upload, then both ways for good.
abstract final class SyncPhase {
  static const download = "download";
  static const upload = "upload";
  static const live = "live";
}

/// The backend's answer to the enrolment, handed over by the app (`task-edge-sync-backend.md` §1).
final class EdgeEnrolment {
  const EdgeEnrolment({
    required this.device,
    required this.company,
    required this.site,
    required this.endpoint,
    required this.edgeKeys,
    required this.allowance,
  });

  /// Throws [EngineFailure] `invalid_field` on an answer that isn't one.
  factory EdgeEnrolment.fromJson(Map<String, Object?> json) {
    String text(String field) => switch (json[field]) {
      final String value when value.isNotEmpty && value.length <= 512 => value,
      _ => throw EngineFailure(ErrorCodes.invalidField, {"field": field}),
    };

    final endpoint = Uri.tryParse(text("endpoint"));
    if (endpoint == null || endpoint.scheme != "https" || endpoint.host.isEmpty) {
      throw const EngineFailure(ErrorCodes.invalidField, {"field": "endpoint"});
    }

    final key = json["edgeKey"];
    if (key is! Map || key["kid"] is! String || key["publicKey"] is! String) {
      throw const EngineFailure(ErrorCodes.invalidField, {"field": "edgeKey"});
    }

    try {
      if (base64.decode(key["publicKey"] as String).length != 32) throw const FormatException();
    } on FormatException {
      throw const EngineFailure(ErrorCodes.invalidField, {"field": "edgeKey"});
    }

    return EdgeEnrolment(
      device: text("device"),
      company: text("company"),
      site: text("site"),
      endpoint: endpoint.toString(),
      edgeKeys: [{"kid": key["kid"], "publicKey": key["publicKey"]}],
      allowance: EdgeAllowance.read(json["allowance"]) ?? EdgeAllowance.within,
    );
  }

  final String device;
  final String company;
  final String site;
  final String endpoint;
  final List<Map<String, Object?>> edgeKeys;
  final String allowance;
}

/// The free allowance, as the backend answers it (D15).
abstract final class EdgeAllowance {
  static const within = "within";
  static const subscribed = "subscribed";
  static const exceeded = "exceeded";

  static String? read(Object? value) => value == within || value == subscribed || value == exceeded ? value as String : null;
}

/// What one [EdgeSync.cycle] did.
final class SyncReport {
  const SyncReport({this.pushed = 0, this.pulled = 0, this.rejected = 0, this.conflicts = 0, this.skipped, this.error});

  final int pushed;
  final int pulled;
  final int rejected;
  final int conflicts;

  /// Why nothing ran: `not_enrolled`, `revoked`, `allowance_exceeded`.
  final String? skipped;

  /// The failure that stopped it, kept as `sync_link.last_error`.
  final String? error;

  bool get ok => skipped == null && error == null;

  @override
  String toString() => "SyncReport(pushed: $pushed, pulled: $pulled, rejected: $rejected, conflicts: $conflicts, "
    "skipped: $skipped, error: $error)";
}

/// The `cloud_id ↔ local_id` map (`sync_ids`): neither side adopts the other's ids (plan §9.2).
final class _Ids {
  const _Ids(this._db);

  final Database _db;

  String? cloud(String entity, String local) =>
    _db.select("SELECT cloud_id FROM sync_ids WHERE entity = ? AND local_id = ?", [entity, local]).firstOrNull?["cloud_id"] as String?;

  String? local(String entity, String cloud) =>
    _db.select("SELECT local_id FROM sync_ids WHERE entity = ? AND cloud_id = ?", [entity, cloud]).firstOrNull?["local_id"] as String?;

  void learn(String entity, String local, String cloud) =>
    _db.execute("INSERT OR IGNORE INTO sync_ids (entity, local_id, cloud_id) VALUES (?, ?, ?)", [entity, local, cloud]);
}

/// The master's half of the edge sync (plan §9, `task-edge-sync-backend.md`). The engine runs it
/// on its own ([cycle], from the runner), app open or not: it pushes the oplog and pulls the
/// cloud's changes, settling each field by its stamp, the same rule the backend applies, so both
/// sides converge without asking each other.
///
/// Everything a cycle learns (ids, stamps, cursors, refusals, conflicts) commits in the same
/// transaction as what it wrote, so a crash between two calls repeats a call, never half of one:
/// the backend answers a repeated `commandId` as `duplicate`, and a pulled change already applied
/// is skipped (`sync_pulled`).
final class EdgeSync {
  EdgeSync(
    this._store,
    this._clock, {
    required this.instance,
    required Future<Uint8List> Function() sealKey,
    required List<EdgeEntity> entities,
    DateTime Function()? now,
    this.batch = 200,
    this.page = 500,
  }) : _sealKey = sealKey,
       _now = now ?? DateTime.now,
       _entities = {for (final entity in entities) entity.name: entity},
       _byLocal = {for (final entity in entities) entity.local: entity},
       _order = entities;

  final Store _store;
  final HlcClock _clock;
  final String instance;
  final Future<Uint8List> Function() _sealKey;
  final DateTime Function() _now;
  final Map<String, EdgeEntity> _entities;
  final Map<String, EdgeEntity> _byLocal;

  /// The upload's order: what a record refers to goes before it.
  final List<EdgeEntity> _order;

  /// Changes per `/commands` call, and per `/changes` page.
  final int batch;
  final int page;

  /// How long a master past its allowance waits before asking again (`task-edge-sync-backend.md` §3).
  static const allowanceRetry = Duration(hours: 1);

  static const _sealContext = "lyra/edge/key";

  Database get _db => _store.db;

  bool _running = false;
  DateTime? _allowanceChecked;

  // -------------------------------------------------------------------------- enrolment

  /// The public key the app registers with the backend: made once and kept, sealed, until
  /// [enroll] takes it, so asking again after a failed registration answers the same key.
  Future<String> prepare() async {
    final pending = _meta("edge_pending");
    if (pending != null) return (jsonDecode(pending) as Map)["publicKey"] as String;

    final pair = await EdgeSigner.generate();
    final sealed = await Envelope.seal(await _sealKey(), pair.seed, context: _sealContext);
    final publicKey = base64.encode(pair.publicKey);

    _store.write((db) => db.execute(
      "INSERT INTO meta (key, value) VALUES ('edge_pending', ?)",
      [jsonEncode({"publicKey": publicKey, "seed": base64.encode(sealed)})],
    ));

    return publicKey;
  }

  /// Takes the backend's answer: the master becomes the edge device it names, for the cloud
  /// company it is linked to (`business.link`), and syncs from its next cycle: the cloud's state
  /// down, its own up, then both ways. Enrolling again (a revoked or reinstalled master) keeps the
  /// ids and stamps it learnt.
  void enroll(EdgeEnrolment enrolment) => _store.write((db) {
    final pending = _meta("edge_pending");
    if (pending == null) throw const EngineFailure("not_prepared");

    final company = db.select("SELECT id, cloud_id FROM company WHERE deleted = 0").firstOrNull;
    if (company == null) throw const EngineFailure(ErrorCodes.notFound);
    if (company["cloud_id"] == null) throw const EngineFailure("not_linked");
    if (company["cloud_id"] != enrolment.company) throw const EngineFailure("company_mismatch");

    final key = jsonDecode(pending) as Map<String, Object?>;
    final site = db.select("SELECT id FROM site").first["id"] as String;
    final seq = Oplog(db).lastSeq;

    db.execute("DELETE FROM sync_link");
    db.execute(
      "INSERT INTO sync_link (one, device, company, site, endpoint, public_key, private_key, edge_keys, allowance, phase, "
      "pushed_seq, indexed_seq, enrolled) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [enrolment.device, enrolment.company, enrolment.site, enrolment.endpoint, key["publicKey"], key["seed"],
        jsonEncode(enrolment.edgeKeys), enrolment.allowance, SyncPhase.download, seq, seq, _instant()],
    );
    db.execute("DELETE FROM meta WHERE key = 'edge_pending'");

    final ids = _Ids(db);
    ids.learn("company", company["id"] as String, enrolment.company);
    ids.learn("site", site, enrolment.site);
  });

  bool get enrolled => _link != null;

  /// Where the edge API is, while enrolled and not revoked.
  String? get endpoint {
    final link = _link;

    return link == null || link["revoked"] == 1 ? null : link["endpoint"] as String;
  }

  /// The backend's keys for the cloud grants (E3), pinned at the enrolment.
  List<Map<String, Object?>> get edgeKeys {
    final link = _link;

    return link == null ? const [] : List<Map<String, Object?>>.from(jsonDecode(link["edge_keys"] as String) as List);
  }

  /// Where the sync stands, for the server section.
  Map<String, Object?> status() {
    final link = _link;
    if (link == null) return const {"enrolled": false};

    return {
      "enrolled": true,
      "device": link["device"],
      "phase": link["phase"],
      "allowance": link["allowance"],
      "revoked": link["revoked"] == 1,
      "lastSync": link["last_sync"],
      "lastError": link["last_error"],
      "pending": _db.select("SELECT count(*) AS n FROM oplog WHERE seq > ? AND coalesce(device, '') != ?",
        [link["pushed_seq"], edgeOrigin]).first["n"],
      "conflicts": _db.select("SELECT count(*) AS n FROM sync_conflicts WHERE status = 'open'").first["n"],
      "rejected": _db.select("SELECT count(*) AS n FROM sync_rejected").first["n"],
    };
  }

  // ------------------------------------------------------------------------------ cycle

  /// Pushes what changed here and pulls what changed in the cloud, once. Never throws for the
  /// network or the backend: the outcome is in the report and in [status].
  Future<SyncReport> cycle(EdgeTransport transport) async {
    if (_running) return const SyncReport(skipped: "running");

    final link = _link;
    if (link == null) return const SyncReport(skipped: "not_enrolled");
    if (link["revoked"] == 1) return const SyncReport(skipped: "revoked");

    _running = true;
    final counts = _Counts();

    try {
      final call = _Caller(this, transport, await EdgeSigner.fromSeed(link["device"] as String,
        await Envelope.open(await _sealKey(), base64.decode(link["private_key"] as String), context: _sealContext), now: _now),
        Uri.parse(link["endpoint"] as String).path);

      if (link["allowance"] == EdgeAllowance.exceeded) {
        final checked = _allowanceChecked;
        if (checked != null && _now().difference(checked) < allowanceRetry) return const SyncReport(skipped: "allowance_exceeded");

        _allowanceChecked = _now();
        await call("GET", "/status");
        if (_link?["allowance"] == EdgeAllowance.exceeded) return const SyncReport(skipped: "allowance_exceeded");
      }

      if (_link?["phase"] == SyncPhase.download) await _download(call, counts);
      if (_link?["phase"] == SyncPhase.upload) await _upload(call, counts);
      if (_link?["phase"] == SyncPhase.live && _unuploaded.isNotEmpty) await _upload(call, counts, only: _unuploaded);
      await _push(call, counts);
      await _pull(call, counts);

      _store.write((db) => db.execute("UPDATE sync_link SET last_sync = ?, last_error = NULL", [_instant()]));

      return counts.report();
    } on EdgeFailure catch (failure) {
      _store.write((db) {
        if (failure.revoked) db.execute("UPDATE sync_link SET revoked = 1");
        if (failure.allowanceExceeded) db.execute("UPDATE sync_link SET allowance = ?", [EdgeAllowance.exceeded]);
        // The cloud no longer keeps where this master was: its whole state again, then on.
        if (failure.cursorExpired) db.execute("UPDATE sync_link SET phase = ?, cursor = NULL", [SyncPhase.download]);
        db.execute("UPDATE sync_link SET last_error = ?", [failure.code]);
      });
      if (failure.allowanceExceeded) _allowanceChecked = _now();

      return counts.report(error: failure.code);
    } on ClockDrift {
      _store.write((db) => db.execute("UPDATE sync_link SET last_error = 'clock_drift'"));

      return counts.report(error: "clock_drift");
    } finally {
      _running = false;
    }
  }

  /// The cloud's whole state for this site (`/snapshot`), applied as pulled changes.
  Future<void> _download(_Caller call, _Counts counts) async {
    String? cursor;

    while (true) {
      final answer = await call("GET", "/snapshot?${_query({"cursor": cursor, "limit": "$page"})}");
      final changes = _changes(answer);

      _store.write((db) {
        for (final change in changes) {
          _applyPulled(db, change, counts);
        }

        if (answer["done"] == true) {
          db.execute("UPDATE sync_link SET phase = ?, cursor = ?", [SyncPhase.upload, answer["changes_cursor"]]);
        }
      });

      if (answer["done"] == true) return;
      cursor = answer["cursor"] as String?;
    }
  }

  /// The master's own state, once, as upserts and appends (`phase: "snapshot"`). What the
  /// download brought is the cloud's already, unless it was edited here since; the company and the
  /// site go up whole either way. The oplog up to this moment is in that state, so the live push
  /// starts after it: nothing goes up twice.
  ///
  /// With [only], a live master uploads the entities a later version added (`sync_link.uploaded`):
  /// their records written before the update, which no oplog entry will ever carry. What the live
  /// push sends of them afterwards finds them mapped.
  Future<void> _upload(_Caller call, _Counts counts, {Set<String>? only}) async {
    final changes = <EdgeChange>[];
    var captured = 0;

    _store.write((db) {
      _index(db);
      captured = Oplog(db).lastSeq;
      final ids = _Ids(db);

      for (final entity in _order) {
        if (only != null && !only.contains(entity.name)) continue;

        for (final id in entity.ids(db)) {
          final mapped = entity.natural ? null : ids.cloud(entity.name, id);
          if (mapped != null && entity.name != "company" && entity.name != "site" && !_editedHere(db, entity.name, id)) continue;

          final row = entity.read(db, id);
          if (row == null || row.deleted) continue;

          final wire = _wire(ids, entity, id);
          final fields = _outFields(ids, entity, row.fields);
          final cells = _outCells(ids, entity, row.cells);

          changes.add(EdgeChange(
            commandId: "$instance:snap:${entity.name}:$id",
            hlc: row.hlc,
            entity: entity.name,
            id: wire,
            op: entity.fact ? EdgeOps.append : EdgeOps.upsert,
            fields: fields,
            cells: cells,
          ));
          if (row.voided case (final reason, final stamp)?) {
            changes.add(EdgeChange(commandId: "$instance:snap:${entity.name}:$id:void", hlc: stamp, entity: entity.name,
              id: wire, op: EdgeOps.voided, fields: reason));
          }

          if (!entity.fact) {
            for (final key in [...row.fields.keys, for (final cell in row.cells.keys) "cells.$cell"]) {
              _stamp(db, entity.name, id, key, row.hlc, local: false);
            }
          }
        }
      }
    });

    for (var start = 0; start < changes.length; start += batch) {
      final chunk = changes.sublist(start, (start + batch).clamp(0, changes.length));
      final answer = await call("POST", "/commands", {"phase": "snapshot", "changes": [for (final change in chunk) change.toJson()]});
      _store.write((db) => _settle(db, chunk, answer, counts));
    }

    final uploaded = jsonEncode(only == null ? [for (final entity in _order) entity.name] : [..._uploaded, ...only]);
    _store.write((db) => only == null
      ? db.execute("UPDATE sync_link SET phase = ?, pushed_seq = max(pushed_seq, ?), uploaded = ?", [SyncPhase.live, captured, uploaded])
      : db.execute("UPDATE sync_link SET uploaded = ?", [uploaded]));
  }

  /// What `sync_link.uploaded` lists; every entity while it lists nothing (a link from before it).
  Set<String> get _uploaded => switch (_link?["uploaded"]) {
    final String list => {for (final name in jsonDecode(list) as List) name as String},
    _ => {for (final entity in _order) entity.name},
  };

  /// The entities a later version added, whose records here were never uploaded.
  Set<String> get _unuploaded => {for (final entity in _order) if (!_uploaded.contains(entity.name)) entity.name};

  bool _editedHere(Database db, String entity, String id) =>
    db.select("SELECT 1 FROM sync_fields WHERE entity = ? AND entity_id = ? AND local = 1", [entity, id]).isNotEmpty;

  /// The oplog since the last push, in order, as changes. A position in the oplog is done once
  /// every change it made has an answer.
  Future<void> _push(_Caller call, _Counts counts) async {
    while (true) {
      final link = _link!;
      final pushed = link["pushed_seq"] as int;
      final entries = Oplog(_db).since(pushed, limit: page);
      if (entries.isEmpty) return;

      final changes = <EdgeChange>[];
      _store.write((db) {
        _index(db);

        final ids = _Ids(db);
        final sent = <String>{};

        for (final entry in entries) {
          if (entry.device == edgeOrigin) continue;

          final entity = _byLocal[entry.entity];
          if (entity == null) continue;

          for (final (n, touch) in entity.touched(db, entry).indexed) {
            final change = _outgoing(db, ids, entry, touch, "$instance:${entry.seq}:$n", sent);
            if (change != null) changes.add(change);
          }
        }
      });

      for (var start = 0; start < changes.length; start += batch) {
        final chunk = changes.sublist(start, (start + batch).clamp(0, changes.length));
        final answer = await call("POST", "/commands", {"phase": "live", "changes": [for (final change in chunk) change.toJson()]});
        _store.write((db) => _settle(db, chunk, answer, counts));
      }

      _store.write((db) => db.execute("UPDATE sync_link SET pushed_seq = ?", [entries.last.seq]));
    }
  }

  /// The cloud's changes after the cursor, page by page; each page commits with its cursor.
  Future<void> _pull(_Caller call, _Counts counts) async {
    while (true) {
      final cursor = _link!["cursor"] as String?;
      final answer = await call("GET", "/changes?${_query({"cursor": cursor, "limit": "$page"})}");
      final changes = _changes(answer);

      _store.write((db) {
        _index(db);
        for (final change in changes) {
          _applyPulled(db, change, counts);
        }
        db.execute("UPDATE sync_link SET cursor = ?, pulled_hlc = ?", [answer["cursor"] ?? cursor, _clock.last.pack()]);
      });

      if (answer["more"] != true) return;
    }
  }

  // ------------------------------------------------------------------------------ push

  EdgeChange? _outgoing(Database db, _Ids ids, OplogEntry entry, EdgeTouch touch, String commandId, Set<String> sent) {
    final entity = _entities[touch.entity]!;
    final wire = _wire(ids, entity, touch.id);
    final unseen = wire.startsWith("m:") && !sent.contains(wire);

    if (touch.op == EdgeOps.delete) {
      // Made and deleted before the cloud ever saw it: nothing to tell.
      if (unseen) return null;

      return EdgeChange(commandId: commandId, hlc: entry.hlc, entity: entity.name, id: wire, op: EdgeOps.delete,
        actor: _email(db, entry.actor));
    }

    final row = entity.read(db, touch.id);
    if (row == null) return null;

    Map<String, Object?> fields;
    Map<String, Object?> cells;

    if (touch.op == EdgeOps.voided) {
      if (row.voided == null) return null;
      fields = row.voided!.$1;
      cells = const {};
    } else if (touch.fields == null && touch.cells == null || unseen) {
      // A record the cloud hasn't seen goes whole, whatever the entry changed.
      fields = row.fields;
      cells = row.cells;
    } else {
      fields = {for (final key in touch.fields ?? const <String>{}) if (row.fields.containsKey(key)) key: row.fields[key]};
      cells = {for (final key in touch.cells ?? const <String>{}) key: row.cells[key]};
    }

    if (touch.op == EdgeOps.upsert && unseen) sent.add(wire);
    if (touch.op == EdgeOps.append) sent.add(wire);

    return EdgeChange(
      commandId: commandId,
      hlc: entry.hlc,
      entity: entity.name,
      id: wire,
      op: touch.op,
      fields: _outFields(ids, entity, fields),
      cells: _outCells(ids, entity, cells),
      actor: _email(db, entry.actor),
    );
  }

  /// Takes the answer to one `/commands` call: the cloud ids it made, its refusals.
  void _settle(Database db, List<EdgeChange> chunk, Map<String, Object?> answer, _Counts counts) {
    final results = answer["results"];
    if (results is! List || results.length != chunk.length) throw const EdgeFailure(502, "bad_answer");

    final ids = _Ids(db);

    for (final (change, result) in [for (var i = 0; i < chunk.length; i++) (chunk[i], results[i])]) {
      if (result is! Map) throw const EdgeFailure(502, "bad_answer");

      switch (result["status"]) {
        case "accepted" || "duplicate":
          counts.pushed++;
          final cloudId = result["cloudId"];
          if (cloudId is String && change.id.startsWith("m:")) ids.learn(change.entity, change.id.substring(2), cloudId);
        case "rejected":
          counts.rejected++;
          db.execute(
            "INSERT OR REPLACE INTO sync_rejected (command_id, direction, entity, entity_id, reason, data, at) VALUES (?, 'push', ?, ?, ?, ?, ?)",
            [change.commandId, change.entity, change.id, result["reason"] as String? ?? "rejected",
              jsonEncode(result["data"] ?? const {}), _instant()],
          );
        default:
          throw const EdgeFailure(502, "bad_answer");
      }
    }
  }

  /// Records the field stamps of the oplog written here since the last time: what each local
  /// write changed, and when. Pulled changes have their stamps already, the cloud's.
  void _index(Database db) {
    final oplog = Oplog(db);

    while (true) {
      final indexed = db.select("SELECT indexed_seq FROM sync_link").first["indexed_seq"] as int;
      final entries = oplog.since(indexed, limit: page);
      if (entries.isEmpty) return;

      for (final entry in entries) {
        if (entry.device == edgeOrigin) continue;

        final entity = _byLocal[entry.entity];
        if (entity == null || entity.fact) continue;

        for (final touch in entity.touched(db, entry)) {
          final target = _entities[touch.entity]!;

          if (touch.op == EdgeOps.delete) {
            _stamp(db, target.name, touch.id, "_deleted", entry.hlc, local: true);
            continue;
          }

          final row = touch.fields == null || touch.cells == null ? target.read(db, touch.id) : null;
          for (final key in touch.fields ?? row?.fields.keys ?? const <String>[]) {
            _stamp(db, target.name, touch.id, key, entry.hlc, local: true);
          }
          for (final cell in touch.cells ?? row?.cells.keys ?? const <String>[]) {
            _stamp(db, target.name, touch.id, "cells.$cell", entry.hlc, local: true);
          }
        }
      }

      db.execute("UPDATE sync_link SET indexed_seq = ?", [entries.last.seq]);
    }
  }

  // ------------------------------------------------------------------------------ pull

  void _applyPulled(Database db, EdgeChange change, _Counts counts) {
    if (db.select("SELECT 1 FROM sync_pulled WHERE command_id = ?", [change.commandId]).isNotEmpty) return;

    void done() => db.execute("INSERT INTO sync_pulled (command_id, at) VALUES (?, ?)", [change.commandId, _instant()]);

    void refuse(String reason, [Map<String, Object?> data = const {}]) {
      counts.rejected++;
      db.execute(
        "INSERT OR REPLACE INTO sync_rejected (command_id, direction, entity, entity_id, reason, data, at) VALUES (?, 'pull', ?, ?, ?, ?, ?)",
        [change.commandId, change.entity, change.id, reason, jsonEncode(data), _instant()],
      );
      done();
    }

    final entity = _entities[change.entity];
    if (entity == null) return refuse("unknown_entity");
    if (!entity.pulls) return done();

    final ids = _Ids(db);
    final known = entity.natural ? (entity.read(db, change.id) == null ? null : change.id) : ids.local(entity.name, change.id);
    final created = known == null;
    final id = known ?? (entity.natural ? change.id : newId());

    if (created && (change.op == EdgeOps.delete || change.op == EdgeOps.voided)) {
      if (change.op == EdgeOps.delete) return done();
      return refuse("unknown_reference");
    }
    // A fact arrives once; the second time is the same fact.
    if (!created && change.op == EdgeOps.append) return done();

    final fields = <String, Object?>{};
    for (final MapEntry(key: field, value: value) in change.fields.entries) {
      final target = entity.refs[field];
      if (target == null || value == null) {
        fields[field] = value;
        continue;
      }

      final local = value is String ? ids.local(target, value) : null;
      if (local == null) return refuse("unknown_reference", {"field": field});
      fields[field] = local;
    }

    final cells = <String, Object?>{};
    for (final MapEntry(key: key, value: value) in change.cells.entries) {
      final local = entity.cellsOf == null ? null : ids.local(entity.cellsOf!, key);
      if (local == null) return refuse("unknown_reference", {"cell": key});
      cells[local] = value;
    }

    final stamp = _clock.receive(change.hlc);
    final boundary = _pulledHlc(db);
    var winners = (fields: fields, cells: cells);

    if (!entity.fact && !created) {
      final current = entity.read(db, id);

      if (change.op == EdgeOps.delete) {
        // An edit newer than the delete brings the record back (§9.3): the delete waits for it.
        final newest = db.select("SELECT max(hlc) AS hlc FROM sync_fields WHERE entity = ? AND entity_id = ? AND field != '_deleted'",
          [entity.name, id]).first["hlc"] as String?;
        if (newest != null && Hlc.parse(newest).compareTo(change.hlc) > 0) {
          _conflict(db, entity.name, id, "_deleted", kept: false, lost: true, keptHlc: Hlc.parse(newest), lostHlc: change.hlc,
            keptSide: "master");
          counts.conflicts++;
          return done();
        }
      } else {
        winners = (
          fields: _settleFields(db, entity.name, id, fields, current?.fields ?? const {}, change.hlc, boundary, "", counts),
          cells: _settleFields(db, entity.name, id, cells, current?.cells ?? const {}, change.hlc, boundary, "cells.", counts),
        );
        if (winners.fields.isEmpty && winners.cells.isEmpty) return done();
      }
    }

    db.execute("SAVEPOINT edge_pull");
    try {
      final written = entity.apply(db, EdgeWrite(
        id: id,
        created: created,
        op: change.op,
        fields: winners.fields,
        cells: winners.cells,
        stamp: stamp,
        commandId: change.commandId,
        now: _now(),
        actor: change.actor,
      ));
      db.execute("RELEASE edge_pull");

      if (created && !entity.natural) ids.learn(entity.name, written, change.id);
      if (!entity.fact) {
        if (change.op == EdgeOps.delete) _stamp(db, entity.name, written, "_deleted", change.hlc, local: false, force: true);
        for (final key in winners.fields.keys) {
          _stamp(db, entity.name, written, key, change.hlc, local: false, force: true);
        }
        for (final key in winners.cells.keys) {
          _stamp(db, entity.name, written, "cells.$key", change.hlc, local: false, force: true);
        }
      }

      counts.pulled++;
      done();
    } on EngineFailure catch (failure) {
      db.execute("ROLLBACK TO edge_pull");
      db.execute("RELEASE edge_pull");
      refuse(failure.code, failure.data);
    } on SqliteException {
      db.execute("ROLLBACK TO edge_pull");
      db.execute("RELEASE edge_pull");
      refuse("invalid");
    }
  }

  /// The fields of a pulled change that win by their stamp. A field written here since the last
  /// pull and changed there to another value is a true concurrent edit: the newer stamp still
  /// wins, and the other value goes to the inbox.
  Map<String, Object?> _settleFields(Database db, String entity, String id, Map<String, Object?> incoming,
      Map<String, Object?> current, Hlc hlc, Hlc? boundary, String prefix, _Counts counts) {
    final winners = <String, Object?>{};

    for (final MapEntry(key: field, value: value) in incoming.entries) {
      final key = "$prefix$field";
      final row = db.select("SELECT hlc, local FROM sync_fields WHERE entity = ? AND entity_id = ? AND field = ?", [entity, id, key]).firstOrNull;
      final mine = row == null ? null : Hlc.parse(row["hlc"] as String);
      final concurrent = row != null && row["local"] == 1 && (boundary == null || mine!.compareTo(boundary) > 0) &&
        jsonEncode(current[field]) != jsonEncode(value);

      if (mine != null && mine.compareTo(hlc) >= 0) {
        if (concurrent) {
          _conflict(db, entity, id, key, kept: current[field], lost: value, keptHlc: mine, lostHlc: hlc, keptSide: "master");
          counts.conflicts++;
        }
        continue;
      }

      winners[field] = value;
      if (concurrent) {
        _conflict(db, entity, id, key, kept: value, lost: current[field], keptHlc: hlc, lostHlc: mine!, keptSide: "cloud");
        counts.conflicts++;
      }
    }

    return winners;
  }

  void _conflict(Database db, String entity, String id, String field,
      {required Object? kept, required Object? lost, required Hlc keptHlc, required Hlc lostHlc, required String keptSide}) =>
    db.execute(
      "INSERT INTO sync_conflicts (id, entity, entity_id, field, kept, kept_side, lost, kept_hlc, lost_hlc, at) "
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [newId(), entity, id, field, jsonEncode(kept), keptSide, jsonEncode(lost), keptHlc.pack(), lostHlc.pack(), _instant()],
    );

  // ------------------------------------------------------------------------------ conflicts

  /// The conflicts inbox (plan §9.3): open ones, newest first.
  List<Map<String, Object?>> conflicts() => [
    for (final row in _db.select("SELECT * FROM sync_conflicts WHERE status = 'open' ORDER BY at DESC, id DESC"))
      {
        "id": row["id"],
        "entity": row["entity"],
        "entityId": row["entity_id"],
        "field": row["field"],
        "kept": jsonDecode(row["kept"] as String),
        "keptSide": row["kept_side"],
        "lost": jsonDecode(row["lost"] as String),
        "at": row["at"],
      },
  ];

  /// Closes a conflict; with [restore], the value that lost is written back as a new edit here,
  /// which the next push carries like any other.
  void resolve(String id, {required bool restore, String? actor}) => _store.write((db) {
    final row = db.select("SELECT * FROM sync_conflicts WHERE id = ? AND status = 'open'", [id]).firstOrNull;
    if (row == null) throw const EngineFailure(ErrorCodes.notFound);

    final field = row["field"] as String;
    if (restore && field != "_deleted") {
      final entity = _entities[row["entity"] as String]!;
      final value = jsonDecode(row["lost"] as String);
      final cell = field.startsWith("cells.");

      entity.apply(db, EdgeWrite(
        id: row["entity_id"] as String,
        created: false,
        op: EdgeOps.upsert,
        fields: cell ? const {} : {field: value},
        cells: cell ? {field.substring(6): value} : const {},
        stamp: _clock.tick(),
        commandId: "restore:$id",
        now: _now(),
        device: null,
        actorAccount: actor,
      ));
    }

    db.execute("UPDATE sync_conflicts SET status = ? WHERE id = ?", [restore ? "restored" : "dismissed", id]);
  });

  // ------------------------------------------------------------------------------ helpers

  Map<String, Object?>? get _link => _db.select("SELECT * FROM sync_link").firstOrNull;

  String? _meta(String key) => _db.select("SELECT value FROM meta WHERE key = ?", [key]).firstOrNull?["value"] as String?;

  Hlc? _pulledHlc(Database db) {
    final value = db.select("SELECT pulled_hlc FROM sync_link").first["pulled_hlc"] as String?;

    return value == null ? null : Hlc.parse(value);
  }

  /// Keeps the newest stamp of a field; [force] takes [hlc] even when older (a pulled value won).
  void _stamp(Database db, String entity, String id, String field, Hlc hlc, {required bool local, bool force = false}) =>
    db.execute(
      "INSERT INTO sync_fields (entity, entity_id, field, hlc, local) VALUES (?, ?, ?, ?, ?) "
      "ON CONFLICT (entity, entity_id, field) DO UPDATE SET hlc = excluded.hlc, local = excluded.local "
      "WHERE ${force ? "1" : "excluded.hlc > sync_fields.hlc"}",
      [entity, id, field, hlc.pack(), local ? 1 : 0],
    );

  String _wire(_Ids ids, EdgeEntity entity, String id) =>
    entity.natural ? id : ids.cloud(entity.name, id) ?? "m:$id";

  Map<String, Object?> _outFields(_Ids ids, EdgeEntity entity, Map<String, Object?> fields) => {
    for (final MapEntry(key: field, value: value) in fields.entries)
      field: entity.refs[field] != null && value is String ? _wire(ids, _entities[entity.refs[field]]!, value) : value,
  };

  Map<String, Object?> _outCells(_Ids ids, EdgeEntity entity, Map<String, Object?> cells) => entity.cellsOf == null
    ? const {}
    : {for (final MapEntry(key: key, value: value) in cells.entries) _wire(ids, _entities[entity.cellsOf]!, key): value};

  String? _email(Database db, String? account) => account == null
    ? null
    : db.select("SELECT email FROM accounts WHERE id = ?", [account]).firstOrNull?["email"] as String?;

  List<EdgeChange> _changes(Map<String, Object?> answer) {
    final changes = answer["changes"];
    if (changes is! List) throw const EdgeFailure(502, "bad_answer");

    try {
      return [for (final change in changes) EdgeChange.fromJson(change)];
    } on FormatException {
      throw const EdgeFailure(502, "bad_answer");
    }
  }

  static String _query(Map<String, String?> values) =>
    [for (final MapEntry(:key, :value) in values.entries) if (value != null) "$key=${Uri.encodeQueryComponent(value)}"].join("&");

  String _instant() => _now().toUtc().toIso8601String();

  /// Every edge answer may carry the allowance and the backend's grant keys; both are kept.
  void _heard(Map<String, Object?> answer) {
    final allowance = EdgeAllowance.read(answer["allowance"]);
    final keys = answer["edgeKeys"];

    if (allowance == null && keys is! List) return;

    _store.write((db) {
      if (allowance != null) db.execute("UPDATE sync_link SET allowance = ?", [allowance]);
      if (keys is List && keys.every((key) => key is Map && key["kid"] is String && key["publicKey"] is String)) {
        db.execute("UPDATE sync_link SET edge_keys = ?", [jsonEncode(keys)]);
      }
    });
  }
}

/// Signs, sends and reads one edge call; an error answer becomes an [EdgeFailure].
final class _Caller {
  _Caller(this._sync, this._transport, this._signer, this._base);

  final EdgeSync _sync;
  final EdgeTransport _transport;
  final EdgeSigner _signer;

  /// The endpoint's path, e.g. `/edge/v1`: every signed path starts with it.
  final String _base;

  Future<Map<String, Object?>> call(String method, String path, [Map<String, Object?>? body]) async {
    final base = _base.endsWith("/") ? _base.substring(0, _base.length - 1) : _base;
    final answer = await _transport.send(await _signer.sign(method, "$base$path", body));

    if (answer.status >= 400 || answer.status < 200) {
      // The edge's own refusals carry a text `code`; anything else in front of it (a 404, a body
      // the server could not read) answers in the API's shape, with the status as a number there.
      final code = answer.body["code"];
      throw EdgeFailure(answer.status, code is String ? code : "http_${answer.status}", answer.body);
    }

    _sync._heard(answer.body);

    return answer.body;
  }
}

final class _Counts {
  int pushed = 0;
  int pulled = 0;
  int rejected = 0;
  int conflicts = 0;

  SyncReport report({String? error}) =>
    SyncReport(pushed: pushed, pulled: pulled, rejected: rejected, conflicts: conflicts, error: error);
}
