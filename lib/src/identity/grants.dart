import 'dart:convert';

import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

/// Where a member's permissions were copied from: a global template (`id` its code) or one of
/// the company's own (`id` its UUID).
typedef TemplateRef = ({String scope, String id});

/// One member's row as stored (`session.md` session.permissions, Member).
final class MemberRow {
  const MemberRow({
    required this.account,
    required this.access,
    required this.all,
    required this.sections,
    required this.template,
    required this.custom,
  });

  final String account;
  final bool access;
  final bool all;

  /// Null: no document, no permission.
  final PermissionSections? sections;
  final TemplateRef? template;
  final bool custom;
}

/// **A person's permissions as stored**: the backend's `grants.js` and `Permissions.load`, on the
/// `members` table (migration 12). Whoever writes a member applies it to their open sessions
/// (`LanServer.regrant`, P-8).
abstract final class Grants {
  /// The account made at setup (S-6), or null before it.
  static String? owner(Database db) =>
    db.select("SELECT value FROM meta WHERE key = 'owner'").firstOrNull?["value"] as String?;

  /// What [account] may do: `all` for the owner whatever is stored (nothing written can lock the
  /// company out of itself), its document while it has access, nothing otherwise (P-1, P-2, P-5).
  static Grant of(Database db, String account) {
    if (account == owner(db)) return Grant.everything();

    final row = read(db, account);
    if (row == null || !row.access) return Grant.none();

    return Grant(all: row.all, sections: row.sections);
  }

  /// Whether [account] may enter the company.
  static bool hasAccess(Database db, String account) => account == owner(db) || (read(db, account)?.access ?? false);

  /// [account]'s row, or null.
  static MemberRow? read(Database db, String account) {
    final row = db.select("SELECT * FROM members WHERE account = ?", [account]).firstOrNull;
    if (row == null) return null;

    final sections = row["sections"] as String?;
    final kind = row["template_kind"] as String?;

    return MemberRow(
      account: account,
      access: row["access"] == 1,
      all: row["all_granted"] == 1,
      sections: sections == null ? null : PermissionCatalog.normalize(jsonDecode(sections)),
      template: kind == null ? null : (scope: kind, id: row["template_id"] as String),
      custom: row["custom"] == 1,
    );
  }

  /// Makes [account] the owner: `meta.owner` and an `all` document copied from `owner`. Inside the
  /// setup's write.
  static void makeOwner(Database db, String account, {required DateTime now}) {
    db.execute("INSERT INTO meta (key, value) VALUES ('owner', ?)", [account]);
    write(db, account, all: true, template: (scope: "global", id: "owner"), now: now);
  }

  /// Lets [account] in with no document if it has none, or back in with the one it kept (P-5).
  static void admit(Database db, String account, {required DateTime now}) => db.execute(
    "INSERT INTO members (account, access, updated) VALUES (?, 1, ?) "
    "ON CONFLICT (account) DO UPDATE SET access = 1, updated = excluded.updated",
    [account, now.toUtc().toIso8601String()],
  );

  /// Takes [account]'s access away; the document stays, so letting them back in starts from it.
  static void revoke(Database db, String account, {required DateTime now, String? by}) => db.execute(
    "UPDATE members SET access = 0, updated = ?, updated_by = ? WHERE account = ?",
    [now.toUtc().toIso8601String(), by, account],
  );

  /// Writes [account]'s whole document and admits them. [sections] is normalized on the way in,
  /// so a stored document never carries a key the catalog doesn't know; `all` stores none.
  static void write(
    Database db,
    String account, {
    bool all = false,
    PermissionSections? sections,
    TemplateRef? template,
    bool custom = false,
    String? by,
    required DateTime now,
  }) => db.execute(
    "INSERT INTO members (account, access, all_granted, sections, template_kind, template_id, custom, updated, "
    "updated_by) VALUES (?1, 1, ?2, ?3, ?4, ?5, ?6, ?7, ?8) ON CONFLICT (account) DO UPDATE SET access = 1, "
    "all_granted = ?2, sections = ?3, template_kind = ?4, template_id = ?5, custom = ?6, updated = ?7, updated_by = ?8",
    [
      account,
      all ? 1 : 0,
      all ? jsonEncode(const {}) : jsonEncode(PermissionCatalog.normalize(sections)),
      template?.scope,
      template?.id,
      custom ? 1 : 0,
      now.toUtc().toIso8601String(),
      by,
    ],
  );
}
