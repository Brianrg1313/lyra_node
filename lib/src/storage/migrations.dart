import 'dart:io';

import 'package:path/path.dart' as p;

import 'migrations/m001_core.dart';
import 'migrations/m002_network.dart';
import 'migrations/m003_business.dart';
import 'migrations/m004_inventory.dart';
import 'migrations/m005_pos.dart';
import 'migrations/m006_money.dart';
import 'migrations/m007_sealed.dart';
import 'migrations/m008_money_methods.dart';
import 'migrations/m009_employees.dart';
import 'migrations/m010_cloud_link.dart';
import 'migrations/m011_sync.dart';
import 'migrations/m012_permissions.dart';
import 'migrations/m013_cloud_members.dart';
import 'migrations/m014_owner_job.dart';
import 'migrations/m015_deliveries.dart';
import 'store.dart';

/// One schema step. [sql] is plain SQLite (several statements). Kept as Dart constants, not
/// `.sql` files, so the compiled engine carries them with nothing to find on disk.
final class Migration {
  const Migration(this.version, this.name, this.sql);

  final int version;
  final String name;
  final String sql;
}

/// Every migration, in order. **Forward only**: a released migration is never edited; a fix is
/// a new one.
const List<Migration> migrations = [m001Core, m002Network, m003Business, m004Inventory, m005Pos, m006Money,
  m007Sealed, m008MoneyMethods, m009Employees, m010CloudLink, m011Sync, m012Permissions,
  m013CloudMembers, m014OwnerJob, m015Deliveries];

/// The database was written by a newer engine. Opening it could lose what that version added,
/// so it's refused (plan §10.2): update the app on the master.
final class DatabaseTooNew implements Exception {
  const DatabaseTooNew(this.found, this.supported);

  final int found;
  final int supported;

  @override
  String toString() => "DatabaseTooNew(found $found, this engine knows up to $supported)";
}

/// Brings [store] to the last version of [steps] (plan §8.1).
///
/// Before touching a database that already has data, it copies the file to [backups]
/// (`pre-migration-<from>-<time>.db`, still encrypted with the same key), so a failed or wrong
/// migration can be undone by hand. Each step is its own transaction together with its
/// `user_version`, so a crash leaves the database at the last step that finished. Answers the
/// versions applied.
List<int> migrate(Store store, {required String backups, List<Migration> steps = migrations, DateTime? now}) {
  final latest = steps.isEmpty ? 0 : steps.last.version;
  final current = store.version;

  if (current > latest) throw DatabaseTooNew(current, latest);

  final pending = steps.where((step) => step.version > current).toList();
  if (pending.isEmpty) return const [];

  if (current > 0) {
    store.checkpoint();

    final stamp = (now ?? DateTime.now()).toUtc().toIso8601String().replaceAll(RegExp(r"[:.]"), "-");
    Directory(backups).createSync(recursive: true);
    File(store.path).copySync(p.join(backups, "pre-migration-$current-$stamp.db"));
  }

  for (final step in pending) {
    store.write((db) {
      db.execute(step.sql);
      db.execute("PRAGMA user_version = ${step.version}");
    });
  }

  return [for (final step in pending) step.version];
}
