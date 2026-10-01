import 'dart:convert';
import 'dart:typed_data';

import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../audit/audit_log.dart';
import '../failure.dart';
import '../ids.dart';
import '../oplog/hlc.dart';
import '../oplog/oplog.dart';
import '../storage/store.dart';
import 'passwords.dart';

enum AccountStatus { pending, active, disabled }

/// [Accounts.pairingAccount]: [id] and [secret] are null for a login that can't pair.
final class PasswordPairingAccount {
  const PasswordPairingAccount({required this.salt, this.id, this.secret, this.lockedUntil});

  final String? id;
  final PasswordSalt salt;
  final String? secret;
  final DateTime? lockedUntil;
}

/// A person who can sign in to this master (`session.md` session.account). The hashes never
/// leave [Accounts].
final class Account {
  const Account({
    required this.id,
    required this.username,
    required this.firstName,
    required this.lastName,
    required this.status,
    required this.grants,
    this.email,
    this.mustChangePassword = false,
    this.lastSignIn,
  });

  final String id;
  final String username;
  final String? email;
  final String firstName;
  final String lastName;
  final AccountStatus status;
  final Set<String> grants;
  final bool mustChangePassword;
  final DateTime? lastSignIn;

  bool get isOwner => grants.contains(ownerGrant);

  /// The grant that holds every permission (`session.md` S-6).
  static const ownerGrant = "*";
}

/// Local accounts: creation of the owner at setup and password checks with lockout. Invitations,
/// activation, PINs and resets arrive with the ops that use them (phase 3 and `employees.md`).
final class Accounts {
  Accounts(
    this._store,
    this._clock, {
    PasswordHasher hasher = const PasswordHasher(),
    DateTime Function()? now,
  }) : _hasher = hasher,
       _now = now ?? DateTime.now;

  /// `session.md` S-4.
  static const maxFailures = 5;
  static const lockout = Duration(minutes: 15);

  /// `session.md` S-2. The bundled list of common passwords is checked too once the catalogues
  /// ship with the app (plan §7.5).
  static const minPasswordLength = 10;

  final Store _store;
  final HlcClock _clock;
  final PasswordHasher _hasher;
  final DateTime Function() _now;
  String? _decoy;

  Database get _db => _store.db;

  bool get isEmpty => _db.select("SELECT 1 FROM accounts LIMIT 1").isEmpty;

  /// The first account, holding `*` (`session.md` S-6). Only while there is no account at all:
  /// afterwards people join by invitation (S-7).
  Future<Account> createOwner({
    required String username,
    required String password,
    required String firstName,
    required String lastName,
    String? email,
    String? device,
  }) async {
    username = username.trim().toLowerCase();
    email = email?.trim().toLowerCase();
    _checkUsername(username);
    _checkPassword(password);
    if (firstName.trim().isEmpty) throw const EngineFailure(ErrorCodes.required, {"field": "firstName"});
    if (lastName.trim().isEmpty) throw const EngineFailure(ErrorCodes.required, {"field": "lastName"});

    final hash = await _hasher.hash(password);
    final id = newId();

    return _store.write((db) {
      if (!isEmpty) throw const EngineFailure("owner_exists");

      final stamp = _clock.tick();
      final now = _now().toUtc().toIso8601String();

      db.execute(
        "INSERT INTO accounts (id, username, email, first_name, last_name, password, status, "
        "created, created_hlc, updated_hlc, origin) VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?)",
        [id, username, email, firstName.trim(), lastName.trim(), hash, now, stamp.pack(), stamp.pack(), device],
      );
      db.execute("INSERT INTO grants (account, permission) VALUES (?, ?)", [id, Account.ownerGrant]);

      // The oplog carries what a client or the sync applies; never a hash.
      Oplog(db).append(
        hlc: stamp,
        entity: "account",
        entityId: id,
        kind: "created",
        payload: {
          "username": username,
          "email": email,
          "firstName": firstName.trim(),
          "lastName": lastName.trim(),
          "grants": [Account.ownerGrant],
        },
        device: device,
      );
      AuditLog(db, now: _now).append(
        AuditKinds.accountCreated,
        actor: id,
        device: device,
        data: {"account": id, "grants": [Account.ownerGrant]},
      );

      return byId(id)!;
    });
  }

  Account? byId(String id) {
    final rows = _db.select("SELECT * FROM accounts WHERE id = ? AND deleted = 0", [id]);

    return rows.isEmpty ? null : _account(rows.first);
  }

  /// The person as the bootstrap's `client` shows them (`session.md` session.bootstrap).
  Map<String, Object?> card(String id) {
    final rows = _db.select("SELECT * FROM accounts WHERE id = ? AND deleted = 0", [id]);
    if (rows.isEmpty) throw const EngineFailure(ErrorCodes.notFound);

    final row = rows.first;

    return {
      "id": row["id"],
      "name": row["first_name"],
      "lastName": row["last_name"],
      "username": row["username"],
      "email": row["email"],
      "sex": row["sex"],
      "picture": row["picture"],
      "birthday": row["birthday"],
    };
  }

  /// Checks a sign in by username or e-mail (`session.md` S-4).
  ///
  /// Every refusal of a wrong login or password is `invalid_credentials`, and an unknown login
  /// costs the same Argon2 time as a known one, so neither the answer nor its timing tells
  /// whether an account exists. A locked account answers `account_locked` with `until`, even to
  /// the right password.
  Future<Account> verifyPassword(String login, String password, {String? device}) async {
    final rows = _db.select(
      "SELECT * FROM accounts WHERE deleted = 0 AND (lower(username) = lower(?1) OR lower(email) = lower(?1))",
      [login.trim()],
    );
    final row = rows.isEmpty ? null : rows.first;
    final hash = row?["password"] as String?;

    if (row == null || hash == null) {
      await _hasher.verify(password, _decoy ??= await _hasher.hash("lyra-decoy-password"));
      throw const EngineFailure("invalid_credentials");
    }

    final id = row["id"] as String;
    final lockedUntil = row["locked_until"] == null ? null : DateTime.parse(row["locked_until"] as String);

    if (lockedUntil != null && lockedUntil.isAfter(_now())) {
      throw EngineFailure("account_locked", {"until": lockedUntil.toUtc().toIso8601String()});
    }

    final matches = await _hasher.verify(password, hash);

    if (!matches) {
      _recordFailure(id, device);
      throw const EngineFailure("invalid_credentials");
    }

    if (row["status"] == AccountStatus.disabled.name) throw const EngineFailure("account_disabled");
    if (row["status"] != AccountStatus.active.name) throw const EngineFailure("invalid_credentials");

    final rehash = _hasher.needsRehash(hash) ? await _hasher.hash(password) : null;

    _store.write((db) => db.execute(
      "UPDATE accounts SET failed_attempts = 0, locked_until = NULL, last_sign_in = ?, "
      "password = coalesce(?, password) WHERE id = ?",
      [_now().toUtc().toIso8601String(), rehash, id],
    ));

    return byId(id)!;
  }

  /// First half of changing [accountId]'s own password (`session.md` S-9): checks the current
  /// one like a sign in (a wrong one counts towards the lockout) and the new one's rules, and
  /// answers its hash for [setPassword]. Split in two so the caller commits the change in its
  /// own write (with its `commandId` answer) after the slow hashing.
  Future<String> newPasswordHash(String accountId, {required String current, required String password, String? device}) async {
    final account = byId(accountId);
    if (account == null) throw const EngineFailure(ErrorCodes.notFound);

    await verifyPassword(account.username, current, device: device);
    _checkPassword(password);

    return _hasher.hash(password);
  }

  void setPassword(String accountId, String hash, {String? device}) => _store.write((db) {
    db.execute(
      "UPDATE accounts SET password = ?, must_change_password = 0, updated_hlc = ? WHERE id = ?",
      [hash, _clock.tick().pack(), accountId],
    );
    AuditLog(db, now: _now).append(AuditKinds.passwordChanged, actor: accountId, device: device, data: {
      "account": accountId,
    });
  });

  /// What the password way of pairing needs for [login] (`protocol-v1.md` §3): how its password
  /// was hashed, and the digest, which is the pairing secret. The digest never leaves the engine.
  ///
  /// A login that can't sign in (unknown, pending, disabled) gets a decoy salt derived from
  /// [decoyKey], the same for every ask, and no secret, so the exchange fails like a wrong
  /// password and nothing tells whether the account exists. A locked one says so, as its sign in
  /// does (S-4).
  PasswordPairingAccount pairingAccount(String login, List<int> decoyKey) {
    login = login.trim().toLowerCase();
    final rows = _db.select(
      "SELECT * FROM accounts WHERE deleted = 0 AND (lower(username) = ?1 OR lower(email) = ?1)",
      [login],
    );
    final row = rows.isEmpty ? null : rows.first;
    final parsed = row?["password"] is String ? PasswordHasher.parse(row!["password"] as String) : null;

    if (row == null || parsed == null || row["status"] != AccountStatus.active.name) {
      return PasswordPairingAccount(salt: PasswordSalt(
        salt: Hashes.hmacSha256(decoyKey, utf8.encode("lyra/pairing/decoy/v1 $login")).sublist(0, 16),
        memory: _hasher.params.memory,
        iterations: _hasher.params.iterations,
        parallelism: _hasher.params.parallelism,
        length: 32,
      ));
    }

    final lockedUntil = row["locked_until"] == null ? null : DateTime.parse(row["locked_until"] as String);

    return PasswordPairingAccount(
      id: row["id"] as String,
      salt: PasswordSalt(
        salt: Uint8List.fromList(parsed.salt),
        memory: parsed.params.memory,
        iterations: parsed.params.iterations,
        parallelism: parsed.params.parallelism,
        length: parsed.hash.length,
      ),
      secret: base64.encode(parsed.hash),
      lockedUntil: lockedUntil != null && lockedUntil.isAfter(_now()) ? lockedUntil : null,
    );
  }

  /// A wrong password in a pairing counts towards [id]'s lockout like a wrong sign in (S-4).
  void pairingFailed(String id) => _recordFailure(id, null);

  /// Whether [login] could sign in with a password (`auth.identify`). Unknown logins answer
  /// true too, so the answer doesn't tell who has an account.
  bool usesPassword(String login) {
    final rows = _db.select(
      "SELECT status FROM accounts WHERE deleted = 0 AND (lower(username) = lower(?1) OR lower(email) = lower(?1))",
      [login.trim()],
    );

    return rows.isEmpty || rows.first["status"] != AccountStatus.pending.name;
  }

  void _recordFailure(String id, String? device) {
    _store.write((db) {
      db.execute("UPDATE accounts SET failed_attempts = failed_attempts + 1 WHERE id = ?", [id]);

      final failures = db.select("SELECT failed_attempts FROM accounts WHERE id = ?", [id]).first;
      final audit = AuditLog(db, now: _now);

      audit.append(AuditKinds.signInFailed, device: device, data: {"account": id});

      if ((failures["failed_attempts"] as int) >= maxFailures) {
        final until = _now().toUtc().add(lockout).toIso8601String();

        db.execute(
          "UPDATE accounts SET failed_attempts = 0, locked_until = ? WHERE id = ?",
          [until, id],
        );
        audit.append(AuditKinds.accountLocked, device: device, data: {"account": id, "until": until});
      }
    });
  }

  Account _account(Row row) => Account(
    id: row["id"] as String,
    username: row["username"] as String,
    email: row["email"] as String?,
    firstName: row["first_name"] as String,
    lastName: row["last_name"] as String,
    status: AccountStatus.values.byName(row["status"] as String),
    mustChangePassword: row["must_change_password"] == 1,
    lastSignIn: row["last_sign_in"] == null ? null : DateTime.parse(row["last_sign_in"] as String),
    grants: {
      for (final grant in _db.select("SELECT permission FROM grants WHERE account = ?", [row["id"]]))
        grant["permission"] as String,
    },
  );

  /// `session.md` S-1: 3 to 32 of `a-z 0-9 . _ -`, starting with a letter.
  static void _checkUsername(String username) {
    if (!RegExp(r"^[a-z][a-z0-9._-]{2,31}$").hasMatch(username)) {
      throw const EngineFailure(ErrorCodes.invalidField, {"field": "username"});
    }
  }

  static void _checkPassword(String password) {
    if (password.length < minPasswordLength) {
      throw const EngineFailure("weak_password", {"field": "password"});
    }
  }
}
