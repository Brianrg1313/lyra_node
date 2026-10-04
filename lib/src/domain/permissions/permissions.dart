import 'dart:convert';

import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../audit/audit_log.dart';
import '../../failure.dart';
import '../../identity/grants.dart';
import '../../ids.dart';
import '../../net/events.dart';
import '../../storage/store.dart';

/// **Who may do what in the company** (`session.md` session.permissions): the backend's `Members`,
/// `Templates` and `Requests` over this master's store, with the same rules and the same refusals,
/// so the app's screens can't tell which one answered.
final class Permissions {
  Permissions(this._store, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// The longest request reason, as the cloud's (`kPermissionReasonMax` in the app).
  static const maxReason = 200;
  static const maxName = 64;
  static const maxDescription = 255;

  final Store _store;
  final DateTime Function() _now;

  Database get _db => _store.db;

  // ---------------------------------------------------------------- permissions.get

  /// The catalog and the asker's own permissions (`GET /permissions`); `online` while they are
  /// the cloud's to change (P-12).
  Map<String, Object?> get(String account) {
    final row = Grants.read(_db, account);
    final grant = Grants.of(_db, account);

    return {
      "catalog": PermissionCatalog.describe(),
      "online": Grants.cloudOwned(_db),
      "mine": {
        "all": grant.all,
        "template": _ref(row?.template),
        "custom": row?.custom ?? false,
        "sections": grant.sections,
      },
    };
  }

  // ---------------------------------------------------------------- templates (P-7)

  /// Every template this company may apply: the global ones in their order, then its own by name.
  List<Map<String, Object?>> templates() => [
    for (final preset in PermissionPresets.all) _preset(preset),
    for (final row in _db.select("SELECT * FROM permission_templates ORDER BY lower(name)")) _own(row),
  ];

  /// `permissions.templates.create {name, description?, from?, permissions?}`: a company template,
  /// optionally starting from another one.
  Map<String, Object?> createTemplate(Map<String, Object?> args, {required String actor}) {
    _local();
    final name = _name(args["name"]);
    final description = _description(args["description"]);
    final from = args["from"];

    var sections = PermissionCatalog.filled(false);
    if (from != null) {
      final source = from is String ? _template(from) : null;
      if (source == null) throw const EngineFailure("permission_template_not_found");
      sections = PermissionCatalog.normalize(source["sections"]);
    }
    sections = _over(sections, args["permissions"]);
    _nameFree(name);

    final id = newId();
    _db.execute(
      "INSERT INTO permission_templates (id, name, description, sections, created, created_by) VALUES (?, ?, ?, ?, ?, ?)",
      [id, name, description, jsonEncode(sections), _now().toUtc().toIso8601String(), actor],
    );

    return {"id": id};
  }

  /// `permissions.templates.edit {id, name?, description?, permissions?}`. The global ones are the
  /// platform's: a company copies one instead (`from`).
  Map<String, Object?> editTemplate(Map<String, Object?> args) {
    _local();
    final row = _ownRow(args["id"]);
    final name = args.containsKey("name") ? _name(args["name"]) : row["name"] as String;
    final description = args.containsKey("description") ? _description(args["description"]) : row["description"];
    final sections = _over(PermissionCatalog.normalize(jsonDecode(row["sections"] as String)), args["permissions"]);

    if (name.toLowerCase() != (row["name"] as String).toLowerCase()) _nameFree(name);

    _db.execute(
      "UPDATE permission_templates SET name = ?, description = ?, sections = ? WHERE id = ?",
      [name, description, jsonEncode(sections), row["id"]],
    );

    return {"id": row["id"]};
  }

  /// `permissions.templates.remove {id}`. Nobody's permissions change: those copied from it only
  /// lose the label.
  Map<String, Object?> removeTemplate(Object? id) {
    _local();
    final row = _ownRow(id);

    _db.execute("DELETE FROM permission_templates WHERE id = ?", [row["id"]]);
    _db.execute(
      "UPDATE members SET template_kind = NULL, template_id = NULL WHERE template_kind = 'company' AND template_id = ?",
      [row["id"]],
    );

    return {"id": row["id"]};
  }

  // ---------------------------------------------------------------- members (P-5, P-6)

  /// Everybody with access, the asker first, then by name.
  List<Map<String, Object?>> members(String viewer) {
    final owner = Grants.owner(_db);
    final rows = _db.select(
      "SELECT a.* FROM accounts a LEFT JOIN members m ON m.account = a.id "
      "WHERE a.deleted = 0 AND a.status = 'active' AND (m.access = 1 OR a.id = ?) "
      "ORDER BY lower(a.first_name), lower(a.last_name)",
      [owner],
    );

    final cards = [for (final row in rows) _card(row, viewer, owner)];
    cards.sort((a, b) => (b["me"] == true ? 1 : 0) - (a["me"] == true ? 1 : 0));

    return cards;
  }

  /// One member with their whole structure: what the editor opens. Also someone with an active
  /// job and no access yet (`access: false`), the state a new member starts from. `online` while
  /// only the cloud changes it (P-12).
  Map<String, Object?> member(Object? username, {required String viewer}) {
    final target = _target(username);
    final owner = Grants.owner(_db);
    final row = _db.select("SELECT * FROM accounts WHERE id = ?", [target.account]).first;

    return {
      ..._card(row, viewer, owner),
      "access": target.access,
      "online": Grants.cloudOwned(_db),
      "sections": Grants.of(_db, target.account).all
        ? PermissionCatalog.filled(true)
        : PermissionCatalog.normalize(Grants.read(_db, target.account)?.sections),
    };
  }

  /// `permissions.members.assign {username, template?, permissions?}`: gives a person access and
  /// permissions, or changes theirs. A template is copied first; `permissions` (partial) is laid
  /// over it, or over what they had. Answers `{username}`, as the cloud does.
  Map<String, Object?> assign(
    Map<String, Object?> args, {
    required String actor,
    required Grant mine,
    String? device,
  }) {
    _local();
    final target = _target(args["username"]);
    _guard(target.account, actor);

    final before = Grants.read(_db, target.account);
    var all = before?.all ?? false;
    var sections = PermissionCatalog.normalize(before?.sections, all: all);
    var origin = before?.template;
    var custom = before?.custom ?? false;

    final template = args["template"];
    if (template != null) {
      final source = template is String ? _template(template) : null;
      if (source == null) throw const EngineFailure("permission_template_not_found");

      all = source["all"] == true;
      sections = PermissionCatalog.normalize(source["sections"]);
      origin = (scope: source["scope"] as String, id: source["id"] as String);
      custom = false;
    }

    final partial = _partial(args["permissions"]);
    if (partial != null && partial.isNotEmpty) {
      // Changing one key of an `all` member makes it explicit: `all` is "whatever exists", and
      // somebody with one thing taken away no longer has that.
      all = false;
      sections = PermissionCatalog.merge(sections, partial);
      custom = origin != null;
    }

    final changed = _mayGrant(mine, before, all, sections);
    final now = _now();

    Grants.write(_db, target.account, all: all, sections: sections, template: origin, custom: custom, by: actor, now: now);
    _changed(target.account, now);
    AuditLog(_db, now: _now).append(AuditKinds.permissionsAssigned, actor: actor, device: device, data: {
      "account": target.account,
      "all": all,
      "template": _ref(origin),
      "changed": changed,
    });

    return {"username": target.username};
  }

  /// `permissions.members.revoke {username}`: their access goes, their document stays.
  Map<String, Object?> revoke(Object? username, {required String actor, required Grant mine, String? device}) {
    _local();
    final target = _target(username);
    if (!target.access) throw const EngineFailure("permission_member_not_found");
    _guard(target.account, actor);

    final changed = _mayGrant(mine, Grants.read(_db, target.account), false, PermissionCatalog.filled(false));
    final now = _now();

    Grants.revoke(_db, target.account, now: now, by: actor);
    _changed(target.account, now);
    AuditLog(_db, now: _now).append(AuditKinds.permissionsRevoked, actor: actor, device: device, data: {
      "account": target.account,
      "changed": changed,
    });

    return {"username": target.username};
  }

  /// The account named [username], or null.
  String? accountOf(Object? username) => username is! String
    ? null
    : _db.select("SELECT id FROM accounts WHERE lower(username) = ?", [username.trim().toLowerCase()]).firstOrNull?["id"]
      as String?;

  // ---------------------------------------------------------------- requests (P-10, P-11)

  /// The asker's own requests, newest first; `state` measured now.
  List<Map<String, Object?>> requests(String account) {
    final held = Grants.of(_db, account).areas.toSet();

    return [
      for (final row in _db.select(
        "SELECT * FROM permission_requests WHERE account = ? ORDER BY created DESC, id DESC",
        [account],
      ))
        {
          "id": row["id"],
          "permission": row["area"],
          "reason": row["reason"],
          "state": held.contains(row["area"]) ? "granted" : row["state"],
          "created": row["created"],
        },
    ];
  }

  /// `permissions.requests.create {permission, reason?}`: records the ask, grants nothing.
  Map<String, Object?> request(Map<String, Object?> args, {required String account}) {
    final area = args["permission"];
    final requires = area is String ? PermissionAreas.requires(area) : null;
    if (requires == null) throw const EngineFailure("permission_request_invalid");
    if (requires.owner) throw const EngineFailure("permission_request_owner");
    if (Grants.of(_db, account).areas.contains(area)) throw const EngineFailure("permission_request_granted");

    final raw = args["reason"];
    if (raw != null && raw is! String) throw const EngineFailure(ErrorCodes.invalidField, {"field": "reason"});
    final reason = (raw as String?)?.trim();
    if (reason != null && reason.length > maxReason) {
      throw const EngineFailure(ErrorCodes.invalidField, {"field": "reason", "max": maxReason});
    }

    final pending = _db.select(
      "SELECT 1 FROM permission_requests WHERE account = ? AND area = ? AND state = 'pending'",
      [account, area],
    );
    if (pending.isNotEmpty) throw const EngineFailure("permission_request_pending");

    final id = newId();
    _db.execute(
      "INSERT INTO permission_requests (id, account, area, keys, reason, created) VALUES (?, ?, ?, ?, ?, ?)",
      [id, account, area, jsonEncode(requires.keys), reason == null || reason.isEmpty ? null : reason,
        _now().toUtc().toIso8601String()],
    );

    return {"id": id};
  }

  // ---------------------------------------------------------------- helpers

  /// Resolves [username] to a person this company may manage: one with a member row, or with an
  /// active job here (P-5, P-6).
  ({String account, String username, bool access}) _target(Object? username) {
    if (username is! String || username.trim().isEmpty) throw const EngineFailure("permission_member_not_found");

    final row = _db.select(
      "SELECT id, username FROM accounts WHERE lower(username) = ? AND deleted = 0",
      [username.trim().toLowerCase()],
    ).firstOrNull;
    if (row == null) throw const EngineFailure("permission_member_not_found");

    final account = row["id"] as String;
    final member = Grants.read(_db, account);
    final job = _db.select("SELECT 1 FROM employments WHERE account = ? AND state = 'active'", [account]).isNotEmpty;
    final owner = account == Grants.owner(_db);

    if (member == null && !job && !owner) throw const EngineFailure("permission_member_not_found");

    return (account: account, username: row["username"] as String, access: owner || (member?.access ?? false));
  }

  /// While the master syncs, permissions are changed in the cloud and arrive by the sync (P-12):
  /// a change made here would be undone by the next one, and security isn't decided offline.
  void _local() {
    if (Grants.cloudOwned(_db)) throw const EngineFailure("permissions_online");
  }

  /// Nobody changes themselves, nobody changes the owner (P-6).
  void _guard(String account, String actor) {
    if (account == actor) throw const EngineFailure("permissions_self");
    if (account == Grants.owner(_db)) throw const EngineFailure("permissions_owner");
  }

  /// Whether [mine] holds everything a change touches: `all` on either side needs `all`, and
  /// every key whose stored value differs must be one [mine] can. Answers the keys changed.
  List<String> _mayGrant(Grant mine, MemberRow? before, bool all, PermissionSections after) {
    if ((all || (before?.all ?? false)) && !mine.all) throw const EngineFailure("escalation");

    final previous = PermissionCatalog.normalize(before?.sections, all: before?.all ?? false);
    final next = PermissionCatalog.normalize(after, all: all);
    final changes = PermissionCatalog.changes(previous, next);

    if (!changes.every(mine.can)) throw const EngineFailure("escalation");

    return changes;
  }

  /// Tells [account]'s sessions their permissions changed (P-8), inside the write.
  void _changed(String account, DateTime now) =>
    EventLog.append(_db, Events.permissionsChanged, {"accountId": account}, at: now, accounts: [account]);

  Map<String, Object?> _card(Row row, String viewer, String? owner) {
    final account = row["id"] as String;
    final member = Grants.read(_db, account);
    final isOwner = account == owner;

    return {
      "username": row["username"],
      "name": row["first_name"],
      "lastName": row["last_name"],
      "picture": row["picture"],
      "me": account == viewer,
      "owner": isOwner,
      "all": isOwner || (member?.all ?? false),
      "template": _named(member?.template),
      "custom": member?.custom ?? false,
    };
  }

  /// A template reference with its name, or null for none (or one that no longer exists).
  Map<String, Object?>? _named(TemplateRef? ref) {
    if (ref == null) return null;

    final template = _template(ref.id);

    return {"scope": ref.scope, "id": ref.id, "name": template?["name"]};
  }

  static Map<String, Object?>? _ref(TemplateRef? ref) => ref == null ? null : {"scope": ref.scope, "id": ref.id};

  /// A template this company may apply, global by code or its own by id, or null.
  Map<String, Object?>? _template(String id) {
    final preset = PermissionPresets.byCode(id);
    if (preset != null) return _preset(preset);

    final row = _db.select("SELECT * FROM permission_templates WHERE id = ?", [id]).firstOrNull;

    return row == null ? null : _own(row);
  }

  Row _ownRow(Object? id) {
    if (id is! String) throw const EngineFailure("permission_template_not_found");
    if (PermissionPresets.byCode(id) != null) throw const EngineFailure("permission_template_global");

    final row = _db.select("SELECT * FROM permission_templates WHERE id = ?", [id]).firstOrNull;
    if (row == null) throw const EngineFailure("permission_template_not_found");

    return row;
  }

  static Map<String, Object?> _preset(PermissionPreset preset) => {
    "id": preset.code,
    "scope": "global",
    "name": preset.name,
    "description": preset.description,
    "all": preset.all,
    "sections": preset.sections,
  };

  static Map<String, Object?> _own(Row row) => {
    "id": row["id"],
    "scope": "company",
    "name": row["name"],
    "description": row["description"],
    "all": false,
    "sections": PermissionCatalog.normalize(jsonDecode(row["sections"] as String)),
  };

  /// [base] with the partial `permissions` a client sent laid over it, if any.
  static PermissionSections _over(PermissionSections base, Object? permissions) {
    final partial = _partial(permissions);

    return partial == null ? base : PermissionCatalog.merge(base, partial);
  }

  /// A client's partial structure, null when absent; an unknown key is refused, never dropped.
  static Map<String, Map<String, bool>>? _partial(Object? permissions) {
    if (permissions == null) return null;

    final read = PermissionCatalog.read(permissions);
    if (!read.ok) throw EngineFailure("permissions_invalid", {"key": read.invalidKey});

    return read.sections;
  }

  static String _name(Object? raw) {
    final name = raw is String ? raw.trim() : "";
    if (name.isEmpty || name.length > maxName) {
      throw const EngineFailure(ErrorCodes.invalidField, {"field": "name", "max": maxName});
    }

    return name;
  }

  static String? _description(Object? raw) {
    if (raw == null) return null;
    if (raw is! String || raw.trim().length > maxDescription) {
      throw const EngineFailure(ErrorCodes.invalidField, {"field": "description", "max": maxDescription});
    }

    return raw.trim().isEmpty ? null : raw.trim();
  }

  void _nameFree(String name) {
    final taken = _db.select("SELECT 1 FROM permission_templates WHERE lower(name) = ?", [name.toLowerCase()]);
    if (taken.isNotEmpty) throw const EngineFailure("permission_template_name_taken");
  }
}
