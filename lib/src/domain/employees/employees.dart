import 'dart:typed_data';

import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../audit/audit_log.dart';
import '../../crypto/sealed.dart';
import '../../failure.dart';
import '../../identity/accounts.dart';
import '../../identity/grants.dart';
import '../../ids.dart';
import '../../oplog/hlc.dart';
import '../../oplog/oplog.dart';
import '../../storage/store.dart';
import '../business/business.dart';
import '../business/zones.dart';

/// One sealed value of an [EmployeeEdit]: [hr] null clears it.
typedef SealedValue = ({String entity, String id, String field, Uint8List? hr, Uint8List? own});

/// An edit checked and its sealed values sealed, ready for [Employees.save]. Made outside the write
/// because sealing is asynchronous and a write isn't.
final class EmployeeEdit {
  const EmployeeEdit._(this.employment, this.account, this.job, this.names, this.sealed);

  /// Null for the person's own `profile.edit`.
  final String? employment;
  final String account;

  /// `employments` columns.
  final Map<String, Object?> job;

  /// `accounts` columns (the names).
  final Map<String, Object?> names;

  final List<SealedValue> sealed;
}

/// Who reads, and what they may open, for [Employees.detail].
typedef EmployeeViewer = ({
  String account,
  String session,
  bool all,
  bool personal,
  Uint8List? hrKey,
  Uint8List? own,
  String? device,
});

/// The company's staff (`employees.md`): employments, the job, the person's profile, and the
/// invitation that creates a pending account with its activation code (E-10, `session.md` S-8).
///
/// A person's private profile and a job's pay are sealed one value per row (`sealed_fields`):
/// to the `hr` scope and to the person ([SealedKeys.sealToScope], [SealedKeys.sealToAccount]), so
/// a write needs nobody's key and the person reads their own without holding `hr` (E-3, E-13).
/// `NOTES` is the company's and is sealed to `hr` only. A value written for someone with no key
/// pair yet (invited, never signed in) gets its own copy the next time an `hr` holder opens it.
final class Employees {
  Employees(this._store, this._clock, this._business, this._accounts, this._sealed, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// E-4: a contract ending within this many days is `expiring`.
  static const expiringDays = 30;

  /// The job's clear keys → `employments` columns (`BRANCH_ID` is checked, never stored: there
  /// is one site).
  static const _jobColumns = {
    "JOB_TITLE": "job_title",
    "DEPARTMENT": "department",
    "EMPLOYEE_CODE": "code",
    "MANAGER_ID": "manager",
    "CONTRACT": "contract",
    "WORKDAY": "workday",
    "START_DATE": "start_date",
    "END_DATE": "end_date",
    "WORK_EMAIL": "work_email",
    "WORK_PHONE": "work_phone",
  };

  static const _nameColumns = {"FIRST_NAME": "first_name", "LAST_NAME": "last_name"};

  /// Sealed keys → the answer's names.
  static const _sealedNames = {
    "SALARY": "salary",
    "SALARY_CURRENCY": "salaryCurrency",
    "PAY_PERIOD": "payPeriod",
    "NOTES": "notes",
    "PHONE": "phone",
    "SEX": "sex",
    "BIRTHDAY": "birthday",
    "ABOUT": "about",
    "DOCUMENT_TYPE": "documentType",
    "DOCUMENT_NUMBER": "documentNumber",
    "NATIONALITY": "nationality",
    "COUNTRY": "country",
    "ADDRESS": "address",
    "CITY": "city",
    "REGION": "region",
    "POSTAL_CODE": "postalCode",
    "EMERGENCY_NAME": "emergencyName",
    "EMERGENCY_PHONE": "emergencyPhone",
    "EMERGENCY_RELATION": "emergencyRelation",
  };

  /// Each text value's ceiling.
  static const _limits = {
    "JOB_TITLE": 120,
    "DEPARTMENT": 80,
    "EMPLOYEE_CODE": 32,
    "WORK_EMAIL": 254,
    "FIRST_NAME": 60,
    "LAST_NAME": 60,
    "ABOUT": 1000,
    "DOCUMENT_NUMBER": 32,
    "ADDRESS": 200,
    "CITY": 80,
    "REGION": 80,
    "POSTAL_CODE": 16,
    "EMERGENCY_NAME": 120,
    "EMERGENCY_RELATION": 60,
    "NOTES": 1000,
  };

  final Store _store;
  final HlcClock _clock;
  final Business _business;
  final Accounts _accounts;
  final SealedKeys _sealed;
  final DateTime Function() _now;

  /// `session/employment` pairs whose sealed fields were already audited (E-16: once per session
  /// per employee). In memory: a restart audits the next read again, which only adds a line.
  final Set<String> _audited = {};

  Database get _db => _store.db;

  // ---------------------------------------------------------------- employees.list / former

  /// `employees.list` (E-1): active and invited employments, the [viewer]'s own card first (an
  /// unfiled one with `id: null` when they have none), then by name. Without [all]
  /// (`business.employees.view`) only that card (plan §5.4). `total` counts the active ones.
  Map<String, Object?> list({required String viewer, required bool all}) {
    final rows = _db.select(
      "SELECT e.*, a.username, a.first_name, a.last_name, a.email, a.picture, a.status AS account_status "
      "FROM employments e JOIN accounts a ON a.id = e.account "
      "WHERE e.state IN ('invited', 'active') AND (?1 OR e.account = ?2)",
      [all ? 1 : 0, viewer],
    );
    final today = _today();
    final cards = [for (final row in rows) _card(row, viewer: viewer, today: today)];

    if (!cards.any((card) => card["me"] == true)) cards.add(_unfiled(viewer));

    cards.sort((a, b) {
      if (a["me"] != b["me"]) return a["me"] == true ? -1 : 1;
      return _sortName(a).compareTo(_sortName(b));
    });

    return {"employees": cards, "total": rows.where((row) => row["state"] == "active").length};
  }

  /// `employees.former` (E-2): ended, declined and cancelled employments, the last to close first.
  List<Map<String, Object?>> former() {
    final rows = _db.select(
      "SELECT e.*, a.username, a.first_name, a.last_name, a.email, a.picture, a.status AS account_status "
      "FROM employments e JOIN accounts a ON a.id = e.account "
      "WHERE e.state IN ('ended', 'declined', 'cancelled') "
      "ORDER BY coalesce(e.ended_date, e.responded, e.invited) DESC, e.id DESC",
    );
    final today = _today();

    return [for (final row in rows) _card(row, viewer: "", today: today)];
  }

  // ---------------------------------------------------------------- employees.detail

  /// `employees.detail {id}` (E-3 to E-7). Private and sealed fields are opened, and answered,
  /// only for a [viewer] who holds `view_personal` with the `hr` key open, or who is that person
  /// with their own key open (a password session); otherwise they are left out and `fullProfile`
  /// is false. `NOTES` only reaches an `hr` holder.
  Future<Map<String, Object?>> detail(String id, EmployeeViewer viewer) async {
    final row = _employmentRow(id);
    final account = row["account"] as String;
    final self = account == viewer.account;

    if (!viewer.all && !self) throw const EngineFailure(ErrorCodes.notFound);

    final hrKey = viewer.personal ? viewer.hrKey : null;
    final own = self ? viewer.own : null;
    final full = hrKey != null || own != null;
    final person = _db.select("SELECT * FROM accounts WHERE id = ?", [account]).first;
    final today = _today();
    final state = row["state"] as String;
    final ended = state == "ended" ? row["ended_date"] as String? : null;

    final sealed = full
      ? {
          ...await _open("person", account, account, hrKey: hrKey, own: own),
          ...await _open("employment", id, account, hrKey: hrKey, own: own),
        }
      : const <String, Object?>{};

    if (hrKey != null && !self && _audited.add("${viewer.session}/$id")) {
      _store.write((db) => AuditLog(db, now: _now).append(AuditKinds.sealedRead, actor: viewer.account,
        device: viewer.device, data: {"scope": SealedScope.hr.name, "what": "employees.detail", "employment": id}));
    }

    final manager = row["manager"] == null ? null : _db.select(
      "SELECT e.id, e.job_title, a.username, a.first_name, a.last_name FROM employments e "
      "JOIN accounts a ON a.id = e.account WHERE e.id = ?",
      [row["manager"]],
    ).firstOrNull;
    final site = _business.site();
    final tenure = _tenure(row, today);
    final stints = _db.select(
      "SELECT * FROM employments WHERE account = ? AND state IN ('active', 'ended') AND start_date IS NOT NULL",
      [account],
    );
    final starts = [for (final stint in stints) stint["start_date"] as String]..sort();

    return {
      "id": id,
      "accountId": account,
      "state": state,
      "contractStatus": _contractStatus(row, today),
      "workStatus": _workStatus(row, today),
      "fullProfile": full,
      // Would be whole, but the session holds no key: one a cloud grant opened (`session.md` S-13).
      "sealedLocked": !full && ((viewer.personal && viewer.hrKey == null) || (self && viewer.own == null)),
      "profileEditable": state == "active",
      "person": {
        "username": person["username"],
        "name": person["first_name"],
        "lastName": person["last_name"],
        "picture": person["picture"],
        "headline": null,
        if (full) ...{
          "email": person["email"],
          for (final key in EmployeeFields.private) _sealedNames[key]!: sealed[key],
        },
      },
      "job": {
        "title": row["job_title"],
        "department": row["department"],
        "code": row["code"],
        "branchId": site["id"],
        "branchName": site["name"],
        "manager": manager == null ? null : {
          "id": manager["id"],
          "username": manager["username"],
          "name": manager["first_name"],
          "lastName": manager["last_name"],
          "jobTitle": manager["job_title"],
        },
        "contract": row["contract"],
        "workday": row["workday"],
        "startDate": row["start_date"],
        "endDate": row["end_date"],
        "workEmail": row["work_email"],
        "workPhone": row["work_phone"],
        if (full) ...{
          // E-7: null is "not filed", never zero.
          "salary": sealed["SALARY"] == null ? null : num.parse(sealed["SALARY"]! as String),
          "salaryCurrency": sealed["SALARY_CURRENCY"],
          "payPeriod": sealed["PAY_PERIOD"],
        },
        if (hrKey != null) "notes": sealed["NOTES"],
      },
      "tenure": tenure,
      "companySince": starts.firstOrNull,
      "companyDays": stints.fold<int>(0, (sum, stint) => sum + (_tenure(stint, today)["totalDays"] ?? 0)),
      "leave": null,
      "upcomingLeaves": const <Object?>[],
      "ended": ended == null ? null : {"date": ended, "reason": row["end_reason"], "note": row["end_note"]},
      "invited": row["invited"],
      "responded": row["responded"],
    };
  }

  // ---------------------------------------------------------------- employees.invite

  /// `employees.invite {email | username, jobTitle, firstName?, lastName?}` (E-10), inside the
  /// op's write. An unknown person gets a `pending` account and the answer carries its activation
  /// code, the only time it leaves the engine. [grant] files the invitation's permissions on the
  /// invited account, in the same write (E-10, P-5).
  Map<String, Object?> invite(
    Map<String, Object?> args, {
    required String actor,
    String? device,
    void Function(String account)? grant,
  }) {
    final email = _optional(args["email"], "email")?.toLowerCase();
    final username = _optional(args["username"], "username")?.toLowerCase();
    final jobTitle = _text("JOB_TITLE", args["jobTitle"]);
    final firstName = _text("FIRST_NAME", args["firstName"]) ?? "";
    final lastName = _text("LAST_NAME", args["lastName"]) ?? "";

    if (email == null && username == null) throw const EngineFailure(ErrorCodes.required, {"field": "email"});
    if (email != null && !_isEmail(email)) throw const EngineFailure(ErrorCodes.invalidField, {"field": "email"});
    if (jobTitle == null) throw const EngineFailure(ErrorCodes.required, {"field": "jobTitle"});

    final existing = _db.select(
      "SELECT id, status FROM accounts WHERE deleted = 0 AND "
      "((?1 IS NOT NULL AND lower(email) = ?1) OR (?2 IS NOT NULL AND lower(username) = ?2))",
      [email, username],
    );
    if (existing.length > 1) throw const EngineFailure(ErrorCodes.invalidField, {"field": "username"});

    final String account;
    if (existing.isEmpty) {
      account = _accounts.createPending(
        username: username, email: email, firstName: firstName, lastName: lastName, actor: actor, device: device);
    } else {
      account = existing.first["id"] as String;
      final open = _db.select(
        "SELECT state FROM employments WHERE account = ? AND state IN ('active', 'invited')", [account]);
      if (open.any((row) => row["state"] == "active")) throw const EngineFailure("already_employed");
      if (open.isNotEmpty) throw const EngineFailure("already_invited");
    }

    final id = newId();
    final stamp = _clock.tick();
    final now = _now().toUtc().toIso8601String();

    _db.execute(
      "INSERT INTO employments (id, account, state, job_title, invited, invited_by, created_hlc, updated_hlc, origin) "
      "VALUES (?, ?, 'invited', ?, ?, ?, ?, ?, ?)",
      [id, account, jobTitle, now, actor, stamp.pack(), stamp.pack(), device],
    );
    Oplog(_db).append(hlc: stamp, entity: "employment", entityId: id, kind: "created",
      payload: {"account": account, "state": "invited", "jobTitle": jobTitle}, actor: actor, device: device);
    AuditLog(_db, now: _now).append(AuditKinds.employeeInvited, actor: actor, device: device, data: {
      "employment": id,
      "account": account,
    });

    grant?.call(account);

    final pending = existing.isEmpty || existing.first["status"] == AccountStatus.pending.name;

    return {"id": id, "activation": pending ? _activation(account, actor: actor, device: device) : null};
  }

  /// `employees.reissueActivation {id}` (E-11): the employment's pending account gets a new code
  /// and the old one stops working.
  Map<String, Object?> reissueActivation(String id, {required String actor, String? device}) =>
    _activation(_employmentRow(id)["account"] as String, actor: actor, device: device);

  Map<String, Object?> _activation(String account, {required String actor, String? device}) {
    final issued = _accounts.issueActivation(account);

    AuditLog(_db, now: _now).append(AuditKinds.activationIssued, actor: actor, device: device, data: {"account": account});

    return {"code": issued.code, "expires": issued.expires.toIso8601String()};
  }

  // ---------------------------------------------------------------- employees.accept

  /// `employees.accept {id}`: the invited person takes the job.
  Map<String, Object?> accept(String id, {required String account, String? device}) {
    final row = _employmentRow(id);
    if (row["account"] != account) throw const EngineFailure(ErrorCodes.notFound);
    if (row["state"] != "invited") throw const EngineFailure("not_invited");

    _start(id, account: account, device: device);

    return const <String, Object?>{};
  }

  /// Activating an account accepts its invitations (S-8: typing the company's code is the
  /// consent). Inside the activation's write.
  void acceptInvitations(String account, {String? device}) {
    for (final row in _db.select("SELECT id FROM employments WHERE account = ? AND state = 'invited'", [account])) {
      _start(row["id"] as String, account: account, device: device);
    }
  }

  void _start(String id, {required String account, String? device}) {
    final stamp = _clock.tick();

    _db.execute(
      "UPDATE employments SET state = 'active', responded = ?, updated_hlc = ? WHERE id = ?",
      [_now().toUtc().toIso8601String(), stamp.pack(), id],
    );
    Oplog(_db).append(hlc: stamp, entity: "employment", entityId: id, kind: "accepted",
      payload: {"state": "active"}, actor: account, device: device);    // A job is membership (`session.md` P-5): in, with nothing granted until someone assigns it.
    Grants.admit(_db, account, now: _now());
  }

  // ---------------------------------------------------------------- employees.edit / profile.edit

  /// The checks of `employees.edit {id, KEY: value}` (E-12, E-14, E-15) and its sealed values
  /// sealed. A key sent empty or null clears it. Pay and person keys need [personal]
  /// (`view_personal`); person keys need an active employment (`profile_locked`). [hrKey], when
  /// open, reads the stored currency a salary's decimals follow.
  Future<EmployeeEdit> draftEdit(Map<String, Object?> args, {required bool personal, Uint8List? hrKey}) async {
    final id = args["id"] is String ? args["id"]! as String : "";
    final row = _employmentRow(id);
    final state = row["state"] as String;
    final account = row["account"] as String;
    final changes = {...args}..remove("id");

    if (changes.isEmpty) throw const EngineFailure(ErrorCodes.badRequest);
    if (state != "invited" && state != "active") throw const EngineFailure("employment_closed");

    for (final key in changes.keys) {
      final known = EmployeeFields.job.contains(key) || EmployeeFields.pay.contains(key) ||
        EmployeeFields.names.contains(key) || EmployeeFields.private.contains(key);
      if (!known) throw EngineFailure(ErrorCodes.invalidField, {"field": key});

      final person = EmployeeFields.names.contains(key) || EmployeeFields.private.contains(key);
      if ((person || EmployeeFields.pay.contains(key)) && !personal) throw const EngineFailure(ErrorCodes.forbidden);
      if (person && state != "active") throw const EngineFailure("profile_locked");
    }

    final job = <String, Object?>{};
    for (final MapEntry(:key, :value) in changes.entries) {
      if (key == "BRANCH_ID") {
        final branch = _optional(value, key);
        if (branch != null && branch != _business.site()["id"]) {
          throw const EngineFailure(ErrorCodes.invalidField, {"field": "BRANCH_ID"});
        }
      } else if (_jobColumns.containsKey(key)) {
        job[_jobColumns[key]!] = _jobValue(key, value, id);
      }
    }

    final start = job.containsKey("start_date") ? job["start_date"] : row["start_date"];
    final end = job.containsKey("end_date") ? job["end_date"] : row["end_date"];
    if (start is String && end is String && start.compareTo(end) > 0) throw const EngineFailure("invalid_dates");

    var decimals = _business.decimals;
    if (changes.containsKey("SALARY")) {
      final currency = changes.containsKey("SALARY_CURRENCY")
        ? _currency(changes["SALARY_CURRENCY"])
        : hrKey == null ? null : await _stored("employment", id, "SALARY_CURRENCY", hrKey);
      if (currency is String) decimals = _decimalsOf(currency);
    }

    return EmployeeEdit._(
      id,
      account,
      job,
      _names(changes),
      await _seal(changes, employment: id, account: account, decimals: decimals),
    );
  }

  /// The checks of `profile.edit {KEY: value}` (E-13): the session's own names and private
  /// profile, with no company permission. The job is not theirs to write.
  Future<EmployeeEdit> draftOwn(Map<String, Object?> args, {required String account}) async {
    if (args.isEmpty) throw const EngineFailure(ErrorCodes.badRequest);

    for (final key in args.keys) {
      if (EmployeeFields.job.contains(key) || EmployeeFields.pay.contains(key)) {
        throw const EngineFailure(ErrorCodes.forbidden);
      }
      if (!EmployeeFields.names.contains(key) && !EmployeeFields.private.contains(key)) {
        throw EngineFailure(ErrorCodes.invalidField, {"field": key});
      }
    }

    return EmployeeEdit._(null, account, const {}, _names(args), await _seal(args, account: account));
  }

  /// Writes an [edit] (inside the op's write). What the oplog carries is never a sealed value,
  /// only which keys changed.
  Map<String, Object?> save(EmployeeEdit edit, {required String actor, String? device}) => _store.write((db) {
    final stamp = _clock.tick();
    final now = _now().toUtc().toIso8601String();

    if (edit.job.isNotEmpty) {
      final columns = {...edit.job, "updated_hlc": stamp.pack()};
      db.execute(
        "UPDATE employments SET ${columns.keys.map((column) => "$column = ?").join(", ")} WHERE id = ?",
        [...columns.values, edit.employment],
      );
    }
    if (edit.names.isNotEmpty) {
      final columns = {...edit.names, "updated_hlc": stamp.pack()};
      db.execute(
        "UPDATE accounts SET ${columns.keys.map((column) => "$column = ?").join(", ")} WHERE id = ?",
        [...columns.values, edit.account],
      );
    }

    for (final value in edit.sealed) {
      if (value.hr == null) {
        db.execute("DELETE FROM sealed_fields WHERE entity = ? AND entity_id = ? AND field = ?",
          [value.entity, value.id, value.field]);
      } else {
        db.execute(
          "INSERT INTO sealed_fields (entity, entity_id, field, hr, own, updated) VALUES (?, ?, ?, ?, ?, ?) "
          "ON CONFLICT (entity, entity_id, field) DO UPDATE SET hr = excluded.hr, own = excluded.own, "
          "updated = excluded.updated",
          [value.entity, value.id, value.field, value.hr, value.own, now],
        );
      }
    }

    final sealedKeys = [for (final value in edit.sealed) value.field];

    if (edit.employment != null && (edit.job.isNotEmpty || sealedKeys.any(EmployeeFields.pay.contains))) {
      Oplog(db).append(hlc: stamp, entity: "employment", entityId: edit.employment!, kind: "edited", payload: {
        ...edit.job,
        "sealed": [for (final key in sealedKeys) if (EmployeeFields.pay.contains(key)) key],
      }, actor: actor, device: device);
    }
    if (edit.names.isNotEmpty || sealedKeys.any(EmployeeFields.private.contains)) {
      Oplog(db).append(hlc: stamp, entity: "account", entityId: edit.account, kind: "edited", payload: {
        ...edit.names,
        "sealed": [for (final key in sealedKeys) if (EmployeeFields.private.contains(key)) key],
      }, actor: actor, device: device);
    }

    return const <String, Object?>{};
  });

  // ---------------------------------------------------------------- internals

  Row _employmentRow(String id) {
    final row = _db.select("SELECT * FROM employments WHERE id = ?", [id]).firstOrNull;
    if (row == null) throw const EngineFailure(ErrorCodes.notFound);

    return row;
  }

  Map<String, Object?> _card(Row row, {required String viewer, required String today}) => {
    "id": row["id"],
    "accountId": row["account"],
    "me": row["account"] == viewer,
    "username": row["username"],
    "name": row["first_name"],
    "lastName": row["last_name"],
    // Only an invitation nobody activated yet: it is how the admin tells who it was for.
    "email": row["account_status"] == AccountStatus.pending.name ? row["email"] : null,
    "picture": row["picture"],
    "headline": null,
    "jobTitle": row["job_title"],
    "department": row["department"],
    "branchId": _business.site()["id"],
    "contract": row["contract"],
    "state": row["state"],
    "workStatus": _workStatus(row, today),
    "startDate": row["start_date"],
    "endedDate": row["ended_date"],
  };

  /// The viewer's card when they have no employment here (the owner, as a rule).
  Map<String, Object?> _unfiled(String viewer) {
    final person = _db.select("SELECT * FROM accounts WHERE id = ?", [viewer]).first;

    return {
      "id": null,
      "accountId": viewer,
      "me": true,
      "username": person["username"],
      "name": person["first_name"],
      "lastName": person["last_name"],
      "email": null,
      "picture": person["picture"],
      "headline": null,
      "jobTitle": null,
      "department": null,
      "branchId": _business.site()["id"],
      "contract": null,
      "state": null,
      "workStatus": null,
      "startDate": null,
      "endedDate": null,
    };
  }

  static String _sortName(Map<String, Object?> card) =>
    fold("${card["name"] ?? ""} ${card["lastName"] ?? ""} ${card["username"] ?? ""}".trim());

  /// The company's calendar day, `YYYY-MM-DD` (E-4).
  String _today() => Zones.local(_business.timezone, _now()).substring(0, 10);

  /// E-4: `not_started` before the start, `working` otherwise; null for anyone not active. Leaves
  /// are planned for later (open question 2), so none is running.
  static String? _workStatus(Row row, String today) {
    if (row["state"] != "active") return null;

    final start = row["start_date"] as String?;

    return start != null && start.compareTo(today) > 0 ? "not_started" : "working";
  }

  /// E-4: `pending`, `expiring`, `expired` or `current` for an open employment; its state for a
  /// closed one.
  static String _contractStatus(Row row, String today) {
    final state = row["state"] as String;
    if (state != "invited" && state != "active") return state;

    final start = row["start_date"] as String?;
    final end = row["end_date"] as String?;

    if (start != null && start.compareTo(today) > 0) return "pending";
    if (end == null) return "current";
    if (end.compareTo(today) < 0) return "expired";

    return _day(end).difference(_day(today)).inDays <= expiringDays ? "expiring" : "current";
  }

  /// E-4: from the start to today, or to the day it ended; nothing before it started.
  static Map<String, int> _tenure(Row row, String today) {
    final start = row["start_date"] as String?;
    final last = row["state"] == "ended" ? (row["ended_date"] as String? ?? today) : today;
    const none = {"years": 0, "months": 0, "days": 0, "totalDays": 0};

    if (start == null || row["state"] == "invited" || start.compareTo(last) > 0) return none;

    final from = _day(start);
    final to = _day(last);
    var years = to.year - from.year;
    var months = to.month - from.month;
    var days = to.day - from.day;

    if (days < 0) {
      months--;
      days += DateTime.utc(to.year, to.month, 0).day;
    }
    if (months < 0) {
      years--;
      months += 12;
    }

    return {"years": years, "months": months, "days": days, "totalDays": to.difference(from).inDays};
  }

  static DateTime _day(String text) =>
    DateTime.utc(int.parse(text.substring(0, 4)), int.parse(text.substring(5, 7)), int.parse(text.substring(8, 10)));

  /// The sealed values of one [entity] row, by key, opened with [hrKey] or, failing that, the
  /// person's [own] key. An `hr` holder fills in the person's copy of a value written before the
  /// person had a key pair.
  Future<Map<String, Object?>> _open(String entity, String id, String account, {Uint8List? hrKey, Uint8List? own}) async {
    final rows = _db.select("SELECT * FROM sealed_fields WHERE entity = ? AND entity_id = ?", [entity, id]);
    final values = <String, Object?>{};
    final mended = <(String, Uint8List)>[];

    for (final row in rows) {
      final field = row["field"] as String;
      final context = _context(entity, id, field);

      if (hrKey != null) {
        values[field] = await _sealed.openWithScope(SealedScope.hr, hrKey, row["hr"] as Uint8List, context: context);

        if (row["own"] == null && field != "NOTES") {
          final copy = await _sealed.sealToAccount(account, values[field], context: context);
          if (copy != null) mended.add((field, copy));
        }
      } else if (own != null && row["own"] != null) {
        values[field] = await _sealed.openWithOwn(own, row["own"] as Uint8List, context: context);
      }
    }

    if (mended.isNotEmpty) {
      _store.write((db) {
        for (final (field, copy) in mended) {
          db.execute("UPDATE sealed_fields SET own = ? WHERE entity = ? AND entity_id = ? AND field = ?",
            [copy, entity, id, field]);
        }
      });
    }

    return values;
  }

  Future<Object?> _stored(String entity, String id, String field, Uint8List hrKey) async {
    final row = _db.select(
      "SELECT hr FROM sealed_fields WHERE entity = ? AND entity_id = ? AND field = ?", [entity, id, field]).firstOrNull;

    return row == null
      ? null
      : _sealed.openWithScope(SealedScope.hr, hrKey, row["hr"] as Uint8List, context: _context(entity, id, field));
  }

  /// [changes]' sealed keys checked and sealed: pay on the employment, the profile on the person.
  Future<List<SealedValue>> _seal(
    Map<String, Object?> changes, {
    String? employment,
    required String account,
    int? decimals,
  }) async {
    final sealed = <SealedValue>[];

    for (final MapEntry(:key, :value) in changes.entries) {
      if (!EmployeeFields.sealed.contains(key)) continue;

      final pay = EmployeeFields.pay.contains(key);
      final entity = pay ? "employment" : "person";
      final id = pay ? employment! : account;
      final clear = _sealedValue(key, value, decimals ?? _business.decimals);

      if (clear == null) {
        sealed.add((entity: entity, id: id, field: key, hr: null, own: null));
        continue;
      }

      final context = _context(entity, id, key);
      final hr = await _sealed.sealToScope(SealedScope.hr, clear, context: context);
      // Nobody ever opened `hr`: the owner's first sign in makes its key.
      if (hr == null) throw const EngineFailure("sealed_locked");

      sealed.add((
        entity: entity,
        id: id,
        field: key,
        hr: hr,
        own: key == "NOTES" ? null : await _sealed.sealToAccount(account, clear, context: context),
      ));
    }

    return sealed;
  }

  static String _context(String entity, String id, String field) => "hr/$entity/$id/$field";

  Map<String, Object?> _names(Map<String, Object?> changes) => {
    for (final MapEntry(:key, :value) in changes.entries)
      if (_nameColumns.containsKey(key))
        _nameColumns[key]!: _text(key, value) ?? (throw EngineFailure(ErrorCodes.required, {"field": key})),
  };

  /// A job key's column value (E-14, E-15); null clears it, which `JOB_TITLE` can't.
  Object? _jobValue(String key, Object? raw, String employment) {
    switch (key) {
      case "JOB_TITLE":
        return _text(key, raw) ?? (throw const EngineFailure(ErrorCodes.required, {"field": "JOB_TITLE"}));
      case "CONTRACT":
        return _pick(key, raw, EmployeeFields.contracts);
      case "WORKDAY":
        return _pick(key, raw, EmployeeFields.workdays);
      case "START_DATE" || "END_DATE":
        return _date(key, raw);
      case "WORK_EMAIL":
        final email = _text(key, raw)?.toLowerCase();
        if (email != null && !_isEmail(email)) throw EngineFailure(ErrorCodes.invalidField, {"field": key});
        return email;
      case "WORK_PHONE":
        return _phone(key, raw);
      case "MANAGER_ID":
        return _manager(_optional(raw, key), employment);
      default:
        return _text(key, raw);
    }
  }

  /// E-14: an invited or active employment of the company, not [employment] itself nor anyone
  /// under it.
  String? _manager(String? manager, String employment) {
    if (manager == null) return null;

    final state = _db.select("SELECT state FROM employments WHERE id = ?", [manager]).firstOrNull?["state"];
    if (state != "active" && state != "invited") {
      throw const EngineFailure(ErrorCodes.invalidField, {"field": "MANAGER_ID"});
    }

    final seen = <String>{};
    for (String? up = manager; up != null && seen.add(up);) {
      if (up == employment) throw const EngineFailure("manager_cycle");
      up = _db.select("SELECT manager FROM employments WHERE id = ?", [up]).firstOrNull?["manager"] as String?;
    }

    return manager;
  }

  /// A sealed key's value as stored (text), or null to clear it.
  String? _sealedValue(String key, Object? raw, int decimals) => switch (key) {
    "SALARY" => _salary(raw, decimals),
    "SALARY_CURRENCY" => _currency(raw),
    "PAY_PERIOD" => _pick(key, raw, EmployeeFields.payPeriods),
    "SEX" => _pick(key, raw, EmployeeFields.sexes),
    "DOCUMENT_TYPE" => _pick(key, raw, EmployeeFields.documents),
    "BIRTHDAY" => _birthday(raw),
    "NATIONALITY" || "COUNTRY" => _country(key, raw),
    "PHONE" || "EMERGENCY_PHONE" => _phone(key, raw),
    _ => _text(key, raw),
  };

  /// E-15: ≥ 0 with at most [decimals] decimals, as canonical decimal text.
  static String? _salary(Object? raw, int decimals) {
    final text = switch (raw) {
      null => null,
      final num number when number.isFinite => "$number",
      final String text => text.trim(),
      _ => throw const EngineFailure(ErrorCodes.invalidField, {"field": "SALARY"}),
    };
    if (text == null || text.isEmpty) return null;

    final match = RegExp(r"^(\d{1,15})(?:\.(\d+))?$").firstMatch(text);
    final fraction = (match?[2] ?? "").replaceFirst(RegExp(r"0+$"), "");
    if (match == null || fraction.length > decimals) throw const EngineFailure(ErrorCodes.invalidField, {"field": "SALARY"});

    final whole = match[1]!.replaceFirst(RegExp(r"^0+(?=\d)"), "");

    return fraction.isEmpty ? whole : "$whole.$fraction";
  }

  /// E-15: the main currency or an active exchange one.
  String? _currency(Object? raw) {
    final code = _optional(raw, "SALARY_CURRENCY")?.toUpperCase();
    if (code == null || code == _business.currency) return code;

    final active = _db.select("SELECT 1 FROM money_currencies WHERE currency = ? AND active = 1", [code]);
    if (active.isEmpty) throw const EngineFailure(ErrorCodes.invalidField, {"field": "SALARY_CURRENCY"});

    return code;
  }

  static int _decimalsOf(String currency) =>
    Catalogs.currencyRows.where((row) => row["code"] == currency).firstOrNull?["decimals"] as int? ?? 2;

  String? _birthday(Object? raw) {
    final day = _date("BIRTHDAY", raw);
    if (day != null && day.compareTo(_today()) > 0) throw const EngineFailure(ErrorCodes.invalidField, {"field": "BIRTHDAY"});

    return day;
  }

  static String? _country(String key, Object? raw) {
    final code = _optional(raw, key)?.toUpperCase();
    if (code != null && !RegExp(r"^[A-Z]{2}$").hasMatch(code)) throw EngineFailure(ErrorCodes.invalidField, {"field": key});

    return code;
  }

  static String? _pick(String key, Object? raw, List<String> values) {
    final value = _optional(raw, key)?.toLowerCase();
    if (value != null && !values.contains(value)) throw EngineFailure(ErrorCodes.invalidField, {"field": key});

    return value;
  }

  /// A calendar day, `YYYY-MM-DD` (E-15).
  static String? _date(String key, Object? raw) {
    final value = _optional(raw, key);
    if (value == null) return null;

    final match = RegExp(r"^(\d{4})-(\d{2})-(\d{2})$").firstMatch(value);
    final parsed = match == null ? null : DateTime.utc(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));
    if (parsed == null || parsed.month != int.parse(match![2]!) || parsed.day != int.parse(match[3]!)) {
      throw EngineFailure(ErrorCodes.invalidField, {"field": key});
    }

    return value;
  }

  static String? _phone(String key, Object? raw) {
    final value = _optional(raw, key);
    if (value != null && !RegExp(r"^\+?[0-9 ()\-]{4,31}$").hasMatch(value)) {
      throw EngineFailure(ErrorCodes.invalidField, {"field": key});
    }

    return value;
  }

  static bool _isEmail(String value) => value.length <= 254 && RegExp(r"^[^\s@]+@[^\s@]+\.[^\s@]+$").hasMatch(value);

  /// A text value: control characters as spaces, spaces collapsed, cut to its ceiling; null when
  /// nothing is left. A value that isn't text is refused.
  static String? _text(String key, Object? raw) {
    final value = _optional(raw, key)?.replaceAll(RegExp(r"[\x00-\x1F\x7F]"), " ").replaceAll(RegExp(r"\s+"), " ");
    if (value == null) return null;

    final max = _limits[key] ?? 120;

    return value.length > max ? value.substring(0, max) : value;
  }

  /// [raw] trimmed, or null when missing or blank; anything but text is refused.
  static String? _optional(Object? raw, String key) {
    if (raw == null) return null;
    if (raw is! String) throw EngineFailure(ErrorCodes.invalidField, {"field": key});

    final value = raw.trim();

    return value.isEmpty ? null : value;
  }
}
