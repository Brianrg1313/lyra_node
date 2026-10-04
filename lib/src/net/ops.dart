import 'dart:convert';
import 'dart:io' show Platform;

import 'package:crypto/crypto.dart' show sha1;
import 'package:lyra_protocol/lyra_protocol.dart';

import '../engine.dart';
import '../failure.dart';
import '../identity/devices.dart';
import '../identity/grants.dart';
import '../audit/audit_log.dart';
import '../crypto/sealed.dart';
import '../domain/business/business.dart';
import '../domain/inventory/inventory.dart';
import '../domain/inventory/spreadsheet.dart';
import '../domain/sales/sales.dart';
import '../sync/edge_sync.dart';
import 'files.dart';
import 'rpc.dart';

/// Every op this engine serves, with its gate (`protocol-v1.md` §9, `session.md`, `business.md`).
/// An op of the catalogue missing here answers `unknown_op`: its domain arrives later in plan
/// phase 4, one domain per release.
///
/// A new op goes into `protocol-v1.md`, `lyra_protocol` (`Ops`), this table with its gate, and a
/// test, in the same change (the app's CLAUDE.md, local ops rule).
final Map<String, OpRule> opRules = {
  Ops.hello.name: const OpRule(_hello, gate: Gate.anyone, whileLocked: true),
  Ops.engineUnlock.name: const OpRule(_unlock, gate: Gate.device, masterOnly: true, whileLocked: true),
  Ops.deviceProve.name: const OpRule(_prove, gate: Gate.anyone),
  Ops.sessionBind.name: const OpRule(_bind, gate: Gate.device),
  Ops.eventsSubscribe.name: const OpRule(_subscribe),
  Ops.eventsUnsubscribe.name: const OpRule(_unsubscribe),
  Ops.authIdentify.name: const OpRule(_identify, gate: Gate.device),
  Ops.authSignIn.name: const OpRule(_signIn, gate: Gate.device),
  Ops.authActivate.name: const OpRule(_activate, gate: Gate.device),
  Ops.authRefresh.name: const OpRule(_refresh, gate: Gate.device),
  Ops.authSignOut.name: const OpRule(_signOut),
  Ops.accountChangePassword.name: const OpRule(_changePassword),
  Ops.devicesList.name: const OpRule(_devices, permission: _devicesPermission),
  Ops.devicesRename.name: const OpRule(_renameDevice, permission: _devicesPermission),
  Ops.devicesRevoke.name: const OpRule(_revokeDevice, permission: _devicesPermission),
  Ops.pairingStart.name: const OpRule(_startPairing, permission: _devicesPermission, masterOnly: true),
  Ops.devicesBrowserCa.name: const OpRule(_browserCa),
  Ops.sessionBootstrap.name: const OpRule(_bootstrap),
  Ops.catalogGet.name: const OpRule(_catalog),
  // The owner's alone, which the handler checks: no grant names it (B-1).
  Ops.businessCreate.name: const OpRule(_createBusiness),
  Ops.businessProfile.name: const OpRule(_profile, permission: _businessView),
  Ops.businessEdit.name: const OpRule(_editProfile, permission: _businessEdit),
  Ops.businessSetLogo.name: const OpRule(_setLogo, permission: _businessEdit),
  Ops.businessLink.name: const OpRule(_link),
  Ops.businessSiteGet.name: const OpRule(_site, permission: _businessView),
  Ops.businessSiteEdit.name: const OpRule(_editSite, permission: _businessEdit),
  // The owner's alone, which the handlers check, as the backend's enrolment is (B-33).
  Ops.syncPrepare.name: const OpRule(_prepareSync),
  Ops.syncEnroll.name: const OpRule(_enrollSync),
  Ops.syncStatus.name: const OpRule(_syncStatus, permission: _serverView),
  Ops.inventoryTablesList.name: const OpRule(_tables, permission: _inventoryView),
  Ops.inventoryTablesCreate.name: const OpRule(_createTable, permission: _productsStructure),
  Ops.inventoryTablesEdit.name: const OpRule(_editTable, permission: _productsStructure),
  Ops.inventoryTablesDelete.name: const OpRule(_deleteTable, permission: _productsStructure),
  Ops.inventoryTablesStructure.name: const OpRule(_structure, permission: _inventoryView),
  Ops.inventoryTablesDetails.name: const OpRule(_details, permission: _inventoryView),
  Ops.inventoryFieldsCreate.name: const OpRule(_createField, permission: _productsStructure),
  // A column's width alone is anyone's who opens the table (I-17); the handler asks for more.
  Ops.inventoryFieldsEdit.name: const OpRule(_editField, permission: _inventoryView),
  Ops.inventoryFieldsDelete.name: const OpRule(_deleteField, permission: _productsStructure),
  Ops.inventoryRecordsList.name: const OpRule(_records, permission: _inventoryView),
  Ops.inventoryRecordsCreate.name: const OpRule(_createRecord, permission: "products.create"),
  Ops.inventoryRecordsEdit.name: const OpRule(_editRecord, permission: "products.edit"),
  Ops.inventoryRecordsDelete.name: const OpRule(_deleteRecord, permission: "products.delete"),
  Ops.inventoryImagesAdd.name: const OpRule(_addImage, permission: "inventory.pictures"),
  Ops.inventoryImagesRemove.name: const OpRule(_removeImage, permission: "inventory.pictures"),
  Ops.inventoryImportStructure.name: const OpRule(_importStructure, permission: _productsStructure),
  Ops.inventoryImportRecords.name: const OpRule(_importRecords, permission: "products.import"),
  Ops.inventoryTablesNormalize.name: const OpRule(_normalize, permission: _productsStructure),
  // Each operation takes its own key, as the cloud's add, remove, return and reserve do: the handler asks.
  Ops.stockMove.name: const OpRule(_move, permission: _stockView),
  Ops.stockHistory.name: const OpRule(_history, permission: _stockView),
  Ops.stockSummary.name: const OpRule(_summary, permission: _stockView),
  Ops.posSummary.name: const OpRule(_posSummary, permission: _posView),
  Ops.posCatalog.name: const OpRule(_posCatalog, permission: _posView),
  Ops.posMethods.name: const OpRule(_posMethods, permission: _posView),
  Ops.posInvoicesOpen.name: const OpRule(_openInvoice, permission: _sell),
  Ops.posInvoicesLine.name: const OpRule(_writeLine, permission: _sell),
  Ops.posInvoicesClose.name: const OpRule(_closeInvoice, permission: _sell),
  Ops.posInvoicesCancel.name: const OpRule(_cancelInvoice, permission: "pos.cancel"),
  Ops.posInvoicesList.name: const OpRule(_openInvoices, permission: _posView),
  Ops.salesList.name: const OpRule(_sales, permission: _salesView),
  Ops.salesCatalog.name: const OpRule(_salesCatalog, permission: _salesView),
  Ops.salesDetail.name: const OpRule(_saleDetail, permission: _salesView),
  Ops.salesFulfil.name: const OpRule(_fulfil, permission: "sales.fulfill"),
  Ops.moneyCatalog.name: const OpRule(_moneyCatalog, permission: _money),
  Ops.moneySummary.name: const OpRule(_moneySummary, permission: _money),
  // A payment and a receivable's collection are both the cloud's `money.charge` (M-7).
  Ops.moneyPaymentsRecord.name: const OpRule(_recordPayment, permission: "money.charge"),
  Ops.moneyPaymentsVoid.name: const OpRule(_voidPayment, permission: "money.void"),
  Ops.moneyPaymentsSearch.name: const OpRule(_payments, permission: _money),
  Ops.moneyReceivables.name: const OpRule(_receivables, permission: _money),
  Ops.moneyMethodsList.name: const OpRule(_methods, permission: _money),
  Ops.moneyMethodsRails.name: const OpRule(_rails, permission: _money),
  Ops.moneyMethodsCreate.name: const OpRule(_createMethod, permission: _accounts, sealedArgs: _sealedMethodArgs),
  Ops.moneyMethodsEdit.name: const OpRule(_editMethod, permission: _accounts, sealedArgs: _sealedMethodArgs),
  Ops.moneyMethodsRemove.name: const OpRule(_removeMethod, permission: _accounts),
  Ops.moneyCurrenciesGet.name: const OpRule(_currencies, permission: _money),
  Ops.moneyCurrenciesSave.name: const OpRule(_saveCurrency, permission: _accounts),
  Ops.moneyCurrenciesRemove.name: const OpRule(_removeCurrency, permission: _accounts),
  Ops.exportAccounting.name: const OpRule(_exportAccounting, permission: "money.export"),
  // Without `employees` a person still reads their own card and detail (E-1, E-3): the handlers
  // shape the answer.
  Ops.employeesList.name: const OpRule(_employees),
  Ops.employeesFormer.name: const OpRule(_formerEmployees, permission: _employeesView),
  Ops.employeesDetail.name: const OpRule(_employee),
  Ops.employeesInvite.name: const OpRule(_invite, permission: _manageEmployees),
  Ops.employeesReissueActivation.name: const OpRule(_reissueActivation, permission: _manageEmployees),
  // Pay and the person's keys also need `view_personal`, which the handler asks for.
  Ops.employeesEdit.name: const OpRule(_editEmployee, permission: _manageEmployees, sealedArgs: EmployeeFields.sealed),
  Ops.employeesAccept.name: const OpRule(_acceptEmployment),
  Ops.profileEdit.name: const OpRule(_editOwnProfile, sealedArgs: EmployeeFields.sealed),
  Ops.permissionsGet.name: const OpRule(_permissions),
  Ops.permissionsTemplatesList.name: const OpRule(_templates, permission: _permissionsView),
  Ops.permissionsTemplatesCreate.name: const OpRule(_createTemplate, permission: _templatesEdit),
  Ops.permissionsTemplatesEdit.name: const OpRule(_editTemplate, permission: _templatesEdit),
  Ops.permissionsTemplatesRemove.name: const OpRule(_removeTemplate, permission: _templatesEdit),
  Ops.permissionsMembersList.name: const OpRule(_members, permission: _permissionsView),
  Ops.permissionsMembersDetail.name: const OpRule(_member, permission: _permissionsView),
  Ops.permissionsMembersAssign.name: const OpRule(_assign, permission: _assignKey),
  Ops.permissionsMembersRevoke.name: const OpRule(_revoke, permission: _assignKey),
  Ops.permissionsRequestsList.name: const OpRule(_requests),
  Ops.permissionsRequestsCreate.name: const OpRule(_request),
};

// The catalog's keys (`session.md` P-4): each op takes the one its cloud route takes.
const _businessView = "business";
const _businessEdit = "business.edit";
const _inventoryView = "products";
const _productsStructure = "products.structure";
const _stockView = "inventory";
const _posView = "pos";
const _sell = "pos.sell";
const _salesView = "sales";
const _money = "money";
const _accounts = "money.accounts";
const _employeesView = "employees";
const _manageEmployees = "employees.manage";
const _permissionsView = "permissions";
const _templatesEdit = "permissions.templates";
const _assignKey = "permissions.assign";

/// The cloud has no employee permission for personal data: whoever reads the staff reads it
/// (`session.md` P-9).
const _viewPersonal = _employeesView;

/// The master's own section (`session.md` P-4), area `local_server`.
const _devicesPermission = "server.devices";

/// Whoever opens that section, which shows the sync with the cloud (B-35).
const _serverView = "server";

/// Whether the session's person can [key] (`session.md` P-1).
bool _allows(OpCall call, String key) => call.connection.grant.can(key);

/// `hello` (`protocol-v1.md` §4). A browser gets a challenge to sign (`device.prove`).
Future<Object?> _hello(OpCall call) async {
  final HelloArgs args;
  try {
    args = HelloArgs.fromJson(call.args);
  } on FormatException {
    throw const EngineFailure(ErrorCodes.badRequest);
  }

  final server = call.connection.server;

  if (args.protocol != protocolVersion) {
    throw const EngineFailure(ErrorCodes.versionMismatch, {"protocol": protocolVersion});
  }
  if (Version.tryParse(args.app)! < Version.tryParse(minAppVersion)!) {
    throw const EngineFailure(ErrorCodes.updateRequired, {"minApp": minAppVersion});
  }

  call.connection.helloDone();

  final connection = call.connection;
  if (connection.isBrowser && connection.device == null) connection.challenge = Hashes.random(32);

  return HelloAnswer(
    protocol: protocolVersion,
    engine: engineVersion,
    minApp: minAppVersion,
    instanceId: server.instanceId,
    state: server.engine == null ? EngineState.locked : EngineState.ready,
    challenge: connection.challenge,
  ).toJson();
}

/// `engine.unlock {passphrase}`: passphrase mode, from the master's own app only (plan §6.2).
Future<Object?> _unlock(OpCall call) async {
  final server = call.connection.server;

  if (server.engine == null) await server.unlock(call.text("passphrase", max: 1024));
  call.connection.identify();

  return {"state": EngineState.ready.name};
}

/// `device.prove {deviceId, signature}`: a browser signs the `hello` challenge with its
/// WebCrypto key (`protocol-v1.md` §3).
Future<Object?> _prove(OpCall call) async {
  final connection = call.connection;
  final challenge = connection.challenge;
  final device = call.engine.devices.byId(call.text("deviceId"));
  final signature = base64.decode(call.text("signature", max: 512));

  connection.challenge = null;

  if (challenge == null || !connection.isBrowser) throw const EngineFailure(ErrorCodes.badRequest);
  if (device == null || device.kind != DeviceKind.web ||
      !P256.verify(device.publicKey, DeviceProof.message(call.engine.instanceId, challenge), signature)) {
    throw const EngineFailure(ErrorCodes.forbidden);
  }
  if (device.isRevoked) throw const EngineFailure(ErrorCodes.deviceRevoked);

  connection.device = device;

  return {"deviceId": device.id, "code": device.code};
}

/// `session.bind {accessToken}` (`protocol-v1.md` §4): only on the device the session belongs
/// to (S-20).
Future<Object?> _bind(OpCall call) async {
  final token = call.text("accessToken");
  final grant = call.engine.sessions.access(token);

  if (grant == null) throw const EngineFailure(ErrorCodes.sessionExpired);
  if (grant.deviceId != call.device.id) throw const EngineFailure(ErrorCodes.sessionRevoked);

  final account = call.engine.accounts.byId(grant.accountId);
  if (account == null) throw const EngineFailure(ErrorCodes.sessionRevoked);

  call.connection.bind(token, grant, account.grant);
  call.engine.devices.touch(call.device.id, account: account.id);

  return {"accountId": account.id, "expires": grant.expires.toIso8601String()};
}

Future<Object?> _subscribe(OpCall call) async {
  final since = call.args["since"];
  if (since != null && (since is! int || since < 0)) throw const EngineFailure(ErrorCodes.invalidField, {"field": "since"});

  return {"head": call.connection.subscribe(since as int?)};
}

Future<Object?> _unsubscribe(OpCall call) async {
  call.connection.unsubscribe();

  return const {};
}

/// `auth.identify {login}`: answers `password` for an unknown login too (`session.md`).
Future<Object?> _identify(OpCall call) async =>
  {"method": call.engine.accounts.usesPassword(call.text("login")) ? "password" : "activation"};

/// `auth.signIn {login, password}` (S-4): 20 attempts a minute per device, then the account
/// rules.
Future<Object?> _signIn(OpCall call) async {
  final server = call.connection.server;
  final device = call.device;

  if (!server.allowSignIn(device.id)) throw const EngineFailure(ErrorCodes.rateLimited, {"retryAfter": 60});

  final password = call.text("password", max: 1024);
  final account = await call.engine.accounts.verifyPassword(call.text("login"), password, device: device.id);
  final tokens = call.engine.sessions.open(accountId: account.id, deviceId: device.id);

  // The sealed keys this person holds open with their password, and only here (plan §6.3).
  await call.engine.sealed.signedIn(account, password, sessionId: tokens.sessionId, refreshToken: tokens.refreshToken);

  return {...tokens.toJson(), "accountId": account.id, "mustChangePassword": account.mustChangePassword};
}

/// `auth.activate {login, code, password}` (S-8): the invited person's password, their account
/// active, their invitations accepted, and a session, as `auth.signIn` answers it. Counts towards
/// the device's sign-in rate.
Future<Object?> _activate(OpCall call) async {
  final engine = call.engine;
  final device = call.device;

  if (!call.connection.server.allowSignIn(device.id)) throw const EngineFailure(ErrorCodes.rateLimited, {"retryAfter": 60});

  final password = call.text("password", max: 1024);
  final (account, hash) = await engine.accounts.checkActivation(
    call.text("login"),
    call.text("code", max: 32),
    password,
    device: device.id,
  );

  engine.store.write((_) {
    engine.accounts.activated(account.id, hash, device: device.id);
    engine.employees.acceptInvitations(account.id, device: device.id);
  });

  final tokens = engine.sessions.open(accountId: account.id, deviceId: device.id);
  await engine.sealed.signedIn(engine.accounts.byId(account.id)!, password,
    sessionId: tokens.sessionId, refreshToken: tokens.refreshToken);

  return {...tokens.toJson(), "accountId": account.id, "mustChangePassword": false};
}

/// `auth.refresh {refreshToken}` (S-21).
Future<Object?> _refresh(OpCall call) async {
  final engine = call.engine;
  final previous = call.text("refreshToken");
  final tokens = engine.sessions.refresh(previous, deviceId: call.device.id);
  final account = engine.accounts.byId(engine.sessions.accountOf(tokens.sessionId) ?? "");

  // The session's sealed keys move to the new token (and come back after a restart).
  await engine.sealed.refreshed(
    tokens.sessionId,
    grant: account?.grant ?? Grant.none(),
    previous: previous,
    next: tokens.refreshToken,
  );

  return tokens.toJson();
}

Future<Object?> _signOut(OpCall call) async {
  call.engine.sessions.end(call.session.sessionId);
  call.connection.unbind();

  return const {};
}

/// `account.changePassword {current, password}` (S-9): every other session of the account ends.
Future<Object?> _changePassword(OpCall call) async {
  final accountId = call.session.accountId;
  final current = call.text("current", max: 1024);
  final password = call.text("password", max: 1024);
  final hash = await call.engine.accounts.newPasswordHash(
    accountId,
    current: current,
    password: password,
    device: call.device.id,
  );
  // The private key of the sealed fields moves to the new password in the same write.
  final wrap = await call.engine.sealed.rewrap(accountId, current: current, password: password);
  final answer = call.write(() {
    call.engine.accounts.setPassword(accountId, hash, device: call.device.id);
    if (wrap != null) call.engine.sealed.save(wrap);
    return const <String, Object?>{};
  });

  final ended = call.engine.sessions.endForAccount(accountId, except: call.session.sessionId, reason: "password_changed");
  call.connection.server.revokeSessions(ended);

  return answer;
}

Future<Object?> _devices(OpCall call) async {
  final server = call.connection.server;

  return [for (final device in call.engine.devices.list()) device.toJson(online: server.isOnline(device.id))];
}

Future<Object?> _renameDevice(OpCall call) async => call.write(() => call.engine.devices
  .rename(call.text("id"), call.text("name"), actor: call.session.accountId, device: call.device.id)
  .toJson(online: call.connection.server.isOnline(call.text("id"))));

/// `devices.revoke {id}` (S-41): its sessions end, its connections close, its certificate is
/// refused from now on.
Future<Object?> _revokeDevice(OpCall call) async {
  final id = call.text("id");
  final answer = call.write(() => call.engine.devices
    .revoke(id, actor: call.session.accountId, device: call.device.id)
    .toJson());

  call.engine.sessions.forgetDevice(id);
  await call.connection.server.dropDevice(id);

  return answer;
}

/// `pairing.start` (S-40): a new code and QR, on the master's own device only.
Future<Object?> _startPairing(OpCall call) async {
  final server = call.connection.server;

  return server.pairing!.open(openedBy: call.session.accountId, transport: server.transport, port: server.port);
}

/// `devices.browserCa`: the name-constrained root, for a signed-in native device to install in
/// its computer's trust store or export for another one (plan §5.3). The pinned channel it comes
/// on already verified it. Installed by hand on another computer, the person compares what the
/// OS shows: Windows shows the SHA-1 `thumbprint`, other systems the SHA-256 `fingerprint`.
/// `host` (the master's `.local` name, none before its company exists), `addresses` and `port`
/// are where a browser then opens the web build.
Future<Object?> _browserCa(OpCall call) async {
  final root = call.engine.authority.browser;
  final server = call.connection.server;

  return {
    "host": server.transport.host,
    "addresses": server.transport.addresses.where((address) => address != "127.0.0.1" && address != "::1").toList(),
    "port": server.port,
    "certificate": base64.encode(root.der),
    "fingerprint": root.fingerprint,
    "thumbprint": sha1.convert(root.der).toString(),
  };
}

/// `session.bootstrap` (`session.md`): what `/init` answers in the cloud, for this master's one
/// company (S-30), with the bundled catalogues (S-32). A master set up without its company answers
/// none and the cloud's `business.none` task (S-31): the app's welcome creates it. Someone without
/// access to it is answered none too (P-5).
Future<Object?> _bootstrap(OpCall call) async {
  final engine = call.engine;
  final business = engine.business;
  final member = business.exists && Grants.hasAccess(engine.store.db, call.session.accountId);

  return {
    "client": engine.accounts.card(call.session.accountId),
    "businesses": [if (member) business.summary()],
    "permissions": {if (member) business.id: call.connection.grant.tree},
    "owned": [if (member && _isOwner(call)) business.id],
    "tasks": [if (!business.exists) {"key": "business.none"}],
    "catalogs": {
      "version": Catalogs.version,
      Catalogs.countries: Catalogs.countryRows,
      Catalogs.currencies: Catalogs.currencyRows,
    },
    "deployment": {
      "mode": "local",
      "instanceId": engine.instanceId,
      "engine": engineVersion,
      "timezone": member ? business.timezone : null,
    },
  };
}

/// `catalog.get {name}` (`business.md`, catalogues): the snapshot this master's release carries.
Future<Object?> _catalog(OpCall call) async {
  final name = call.text("name", max: 64);
  final rows = Catalogs.named(name);
  if (rows == null) throw const EngineFailure(ErrorCodes.notFound, {"field": "name"});

  return {"version": Catalogs.version, "items": rows};
}

bool _isOwner(OpCall call) => Grants.owner(call.engine.store.db) == call.session.accountId;

/// `business.create {name, country, currency, language, activity?}` (B-1): the owner creates the
/// company of a master set up without one, once.
Future<Object?> _createBusiness(OpCall call) async {
  if (!_isOwner(call)) throw const EngineFailure(ErrorCodes.forbidden);

  final answer = call.write(() {
    final engine = call.engine;
    if (engine.business.exists) throw const EngineFailure("company_exists");

    Business.create(engine.store.db, CompanyDraft.fromJson(call.args), clock: engine.clock, now: engine.now(), actor: call.session.accountId);

    return engine.business.summary();
  });
  call.connection.server.onCompanyCreated?.call();

  return answer;
}

Future<Object?> _profile(OpCall call) async => call.engine.business.profile(owner: _isOwner(call));

/// `business.edit {KEY: value}` (B-2): one key per call.
Future<Object?> _editProfile(OpCall call) async => call.write(() =>
  call.engine.business.edit(call.args, owner: _isOwner(call), actor: call.session.accountId, device: call.device.id));

/// `business.setLogo {fileId}` (B-8): a `logo` upload of this account, or null to remove it.
Future<Object?> _setLogo(OpCall call) async {
  final fileId = call.args["fileId"];
  if (fileId != null && fileId is! String) throw const EngineFailure(ErrorCodes.invalidField, {"field": "fileId"});

  return call.write(() => call.engine.business.setLogo(
    fileId as String?,
    call.engine.files,
    owner: _isOwner(call),
    actor: call.session.accountId,
    device: call.device.id,
  ));
}

/// `business.link {cloudId}` (B-30, B-31): the owner makes the company one with its cloud twin.
Future<Object?> _link(OpCall call) async {
  if (!_isOwner(call)) throw const EngineFailure(ErrorCodes.forbidden);

  final cloudId = call.text("cloudId", max: 64);

  return call.write(() => call.engine.business.link(cloudId, actor: call.session.accountId, device: call.device.id));
}

Future<Object?> _site(OpCall call) async => call.engine.business.site();

/// `business.site.edit {changed keys}` (B-10 to B-12).
Future<Object?> _editSite(OpCall call) async => call.write(() =>
  call.engine.business.editSite(call.args, actor: call.session.accountId, device: call.device.id));

/// `sync.prepare` (B-33): the edge key the app registers with the backend, and what the
/// enrolment names this master by. The same key until `sync.enroll` takes it.
Future<Object?> _prepareSync(OpCall call) async {
  if (!_isOwner(call)) throw const EngineFailure(ErrorCodes.forbidden);

  final publicKey = await call.engine.edge.prepare();
  final host = Platform.localHostname.trim();

  return call.write(() => {
    "publicKey": publicKey,
    "instance": call.engine.instanceId,
    "engine": engineVersion,
    "name": host.isEmpty ? call.engine.business.profile(owner: true)["name"] : (host.length > 64 ? host.substring(0, 64) : host),
  });
}

/// `sync.enroll {device, company, site, edgeKey, allowance, endpoint}` (B-33, B-34): the backend's
/// answer to the enrolment, as it came. Answers `sync.status`.
Future<Object?> _enrollSync(OpCall call) async {
  if (!_isOwner(call)) throw const EngineFailure(ErrorCodes.forbidden);

  final enrolment = EdgeEnrolment.fromJson(call.args);

  return call.write(() {
    call.engine.edge.enroll(enrolment);
    call.engine.audit.append(AuditKinds.syncEnrolled, actor: call.session.accountId, device: call.device.id,
      data: {"device": enrolment.device, "company": enrolment.company, "site": enrolment.site});

    return call.engine.edge.status();
  });
}

/// `sync.status` (B-35): where the sync with the cloud stands.
Future<Object?> _syncStatus(OpCall call) async => call.engine.edge.status();

// ---------------------------------------------------------------- inventory (`inventory.md`)

Future<Object?> _tables(OpCall call) async => call.engine.inventory.tables();

Future<Object?> _createTable(OpCall call) async => call.write(() =>
  call.engine.inventory.createTable(call.args, actor: call.session.accountId, device: call.device.id));

Future<Object?> _editTable(OpCall call) async => call.write(() =>
  call.engine.inventory.editTable(call.args, actor: call.session.accountId, device: call.device.id));

/// `inventory.tables.delete {id}` (I-2, I-4).
Future<Object?> _deleteTable(OpCall call) async => call.write(() {
  call.engine.inventory.deleteTable(call.text("id"), actor: call.session.accountId, device: call.device.id);
  return const <String, Object?>{};
});

Future<Object?> _structure(OpCall call) async => call.engine.inventory.structure(call.text("id"));

Future<Object?> _details(OpCall call) async => call.engine.inventory.details(call.text("id"));

Future<Object?> _createField(OpCall call) async => call.write(() =>
  call.engine.inventory.createField(call.args, actor: call.session.accountId, device: call.device.id));

/// `inventory.fields.edit`: anything past the width needs `products.structure` (I-17).
Future<Object?> _editField(OpCall call) async {
  final inventory = call.engine.inventory;
  if (!inventory.onlyWidth(call.args) && !_allows(call, _productsStructure)) {
    throw const EngineFailure(ErrorCodes.forbidden);
  }

  return call.write(() => inventory.editField(call.args,
    actor: call.session.accountId, device: call.device.id, decimals: _decimals(call)));
}

/// `inventory.fields.delete {id}` (I-16): recorded in the audit log with how many values went.
Future<Object?> _deleteField(OpCall call) async => call.write(() {
  final engine = call.engine;
  final deleted = engine.inventory.deleteField(call.text("id"), actor: call.session.accountId, device: call.device.id);

  engine.audit.append(AuditKinds.fieldDeleted, actor: call.session.accountId, data: {
    "table": deleted.table,
    "field": call.args["id"],
    "name": deleted.name,
    "values": deleted.values,
  });

  return const <String, Object?>{};
});

Future<Object?> _records(OpCall call) async => call.engine.inventory.records(
  call.text("tableId"),
  page: _int(call, "page", 1),
  size: _int(call, "size", 50),
  match: call.args["match"] == null ? "" : call.text("match", max: 200),
);

Future<Object?> _createRecord(OpCall call) async => call.write(() => call.engine.inventory.createRecord(
  call.text("tableId"), call.args["data"],
  decimals: _decimals(call), actor: call.session.accountId, device: call.device.id,
));

Future<Object?> _editRecord(OpCall call) async => call.write(() {
  call.engine.inventory.editRecord(call.text("tableId"), call.text("id"), call.args["data"],
    decimals: _decimals(call), actor: call.session.accountId, device: call.device.id);
  return const <String, Object?>{};
});

Future<Object?> _deleteRecord(OpCall call) async => call.write(() {
  call.engine.inventory.deleteRecord(call.text("tableId"), call.text("id"), actor: call.session.accountId, device: call.device.id);
  return const <String, Object?>{};
});

/// `inventory.images.add {tableId, productId, fileId}` (I-30, I-31): a `product_image` upload of
/// this account.
Future<Object?> _addImage(OpCall call) async => call.write(() => call.engine.inventory.addImage(
  call.text("tableId"), call.text("productId"), call.text("fileId"), call.engine.files,
  actor: call.session.accountId, device: call.device.id,
));

Future<Object?> _removeImage(OpCall call) async => call.write(() => call.engine.inventory.removeImage(
  call.text("tableId"), call.text("productId"), call.text("fileId", max: 2048), call.engine.files,
  actor: call.session.accountId, device: call.device.id,
));

/// `inventory.import.structure {fileId, format, name?, row}` (I-40 to I-45): the upload is read
/// once, off the server's isolate, then deleted.
Future<Object?> _importStructure(OpCall call) async {
  final (fileId, sheet) = await _sheet(call);
  final name = call.args["name"] == null ? null : call.text("name", max: 200);
  final answer = call.write(() => call.engine.inventory.importStructure(sheet,
    name: name, actor: call.session.accountId, device: call.device.id));

  call.engine.files.discard(fileId);
  return answer;
}

/// `inventory.import.records {fileId, format, tableId, row}` (I-44 to I-46): the rows, and a
/// stock column's opening balances as `add` / `restock` movements noted "import", in the same
/// write.
Future<Object?> _importRecords(OpCall call) async {
  final tableId = call.text("tableId");
  final (fileId, sheet) = await _sheet(call);
  final engine = call.engine;
  final answer = call.write(() {
    final result = engine.inventory.importRecords(tableId, sheet,
      decimals: _decimals(call), actor: call.session.accountId, device: call.device.id);

    for (final (productId, units) in result.opening) {
      engine.stock.move(
        operation: StockOperations.add,
        tableId: tableId,
        productId: productId,
        quantity: units,
        reason: "restock",
        note: "import",
        source: "import",
        actor: call.session.accountId,
        device: call.device.id,
        announce: false,
      );
    }

    return {"imported": result.imported, "withInvalidCells": result.withInvalidCells};
  });

  engine.files.discard(fileId);
  return answer;
}

/// The import's upload read as a sheet (I-40, I-41).
Future<(String, Sheet)> _sheet(OpCall call) async {
  final fileId = call.text("fileId");
  final format = call.text("format", max: 16);
  final row = _int(call, "row", 1);
  final bytes = await call.engine.files.once(fileId, FilePurpose.import, uploader: call.session.accountId);

  return (fileId, await Sheet.read(bytes, format, row));
}

/// `inventory.tables.normalize {tableId}` (I-47).
Future<Object?> _normalize(OpCall call) async => call.write(() => call.engine.inventory.normalize(
  call.text("tableId"), decimals: _decimals(call), actor: call.session.accountId, device: call.device.id,
));

/// How many decimals the company's currency writes a price with (I-21).
int _decimals(OpCall call) {
  final currency = call.engine.business.summary()["currency"];

  return Catalogs.currencyRows.where((row) => row["code"] == currency).firstOrNull?["decimals"] as int? ?? 2;
}

int _int(OpCall call, String name, int fallback) {
  final value = call.args[name] ?? fallback;
  if (value is! int) throw EngineFailure(ErrorCodes.invalidField, {"field": name});

  return value;
}

// ---------------------------------------------------------------- stock (`stock.md`)

/// `stock.move {operation, tableId, productId, quantity, reason?, note?}` (ST-10 to ST-16).
Future<Object?> _move(OpCall call) async {
  final operation = call.text("operation", max: 16);
  final key = _stockKeys[operation];
  if (key != null && !_allows(call, key)) throw const EngineFailure(ErrorCodes.forbidden);

  return call.write(() => call.engine.stock.move(
  operation: operation,
  tableId: call.text("tableId"),
  productId: call.text("productId"),
  quantity: call.args["quantity"],
  reason: call.args["reason"],
  note: call.args["note"],
  actor: call.session.accountId,
  device: call.device.id,
  commandId: call.request.commandId,
));
}

/// The key each stock operation takes: the cloud's route for it (`stock/add`, `stock/remove`…).
/// An operation the ledger doesn't know is left to it to refuse.
const _stockKeys = {
  StockOperations.add: "inventory.restock",
  StockOperations.remove: "inventory.remove",
  StockOperations.receiveReturn: "inventory.return",
  StockOperations.reserve: "inventory.hold",
  StockOperations.unreserve: "inventory.hold",
};

Future<Object?> _history(OpCall call) async => call.engine.stock.history(
  call.text("productId"),
  cursor: call.args["cursor"] == null ? null : call.text("cursor", max: 64),
  size: _int(call, "size", 50),
);

Future<Object?> _summary(OpCall call) async => call.engine.stock.summary(
  page: _int(call, "page", 1),
  size: _int(call, "size", 30),
  match: call.args["match"] == null ? "" : call.text("match", max: 200),
);

// ---------------------------------------------------------------- pos (`pos.md`)

Future<Object?> _posSummary(OpCall call) async => call.engine.pos.summary(call.session.accountId);

Future<Object?> _posMethods(OpCall call) async => call.engine.pos.methods();

/// `pos.catalog {size, cursor?, search?, category?}` (POS-1 to POS-4).
Future<Object?> _posCatalog(OpCall call) async => call.engine.pos.catalog(
  size: _int(call, "size", 30),
  cursor: call.args["cursor"] == null ? null : call.text("cursor", max: 2048),
  search: call.args["search"] == null ? "" : call.text("search", max: 200),
  category: call.args["category"] == null ? "" : call.text("category", max: 1000),
);

/// `pos.invoices.open {tax?}` (POS-10, POS-40): the code is this device's.
Future<Object?> _openInvoice(OpCall call) async => call.write(() => call.engine.pos.open(
  tax: call.args["tax"],
  seller: call.session.accountId,
  device: call.device.id,
  deviceCode: call.device.code,
));

/// `pos.invoices.line` (POS-11 to POS-18).
Future<Object?> _writeLine(OpCall call) async => call.write(() => call.engine.pos.line(
  call.text("id"),
  call.args,
  actor: call.session.accountId,
  device: call.device.id,
));

/// `pos.invoices.close {id, method, reference?, note?}` (POS-30 to POS-36).
Future<Object?> _closeInvoice(OpCall call) async => call.write(() => call.engine.pos.close(
  call.text("id"),
  method: call.args["method"],
  reference: call.args["reference"],
  note: call.args["note"],
  actor: call.session.accountId,
  device: call.device.id,
));

/// `pos.invoices.cancel {id}` (POS-35, POS-36).
Future<Object?> _cancelInvoice(OpCall call) async => call.write(() {
  call.engine.pos.cancel(call.text("id"), actor: call.session.accountId, device: call.device.id);
  return const <String, Object?>{};
});

/// `pos.invoices.list {mine?, size?}` (POS-45): `mine` is this device, not the person.
Future<Object?> _openInvoices(OpCall call) async {
  final mine = call.args["mine"];
  if (mine != null && mine is! bool) throw const EngineFailure(ErrorCodes.invalidField, {"field": "mine"});

  return call.engine.pos.list(device: mine == true ? call.device.id : null, size: _int(call, "size", 20));
}

// ---------------------------------------------------------------- sales (`sales.md`)

/// `sales.list {section, stage?, channel?, mine?, page?, size?}` (SA-10 to SA-13): a stage names
/// its own section. Both sections are the cloud's `sales`, which the op already asks for.
Future<Object?> _sales(OpCall call) async {
  final stage = call.args["stage"] == null ? null : call.text("stage", max: 32);
  final kind = stage == null ? null : SaleStages.kinds[stage];
  if (stage != null && kind == null) throw const EngineFailure(ErrorCodes.invalidField, {"field": "stage"});

  final section = kind?.$1 ?? call.text("section", max: 16);
  if (section != SaleStages.process && section != SaleStages.done) {
    throw const EngineFailure(ErrorCodes.invalidField, {"field": "section"});
  }

  final page = _int(call, "page", 1);
  final size = _int(call, "size", 30);
  if (page < 1) throw const EngineFailure(ErrorCodes.invalidField, {"field": "page"});
  if (size < 1 || size > PosLimits.maxPage) throw const EngineFailure(ErrorCodes.invalidField, {"field": "size"});

  return call.engine.sales.list(
    section: section,
    stage: stage,
    channel: call.args["channel"] == null ? null : call.text("channel", max: 32),
    seller: _bool(call, "mine") ? call.session.accountId : _seller(call),
    page: page,
    size: size,
  );
}

Future<Object?> _salesCatalog(OpCall call) async => call.engine.sales.catalog();

/// `sales.detail {reference}` (SA-30): a ticket code or a row id.
Future<Object?> _saleDetail(OpCall call) async =>
  call.engine.sales.detail(call.text("reference", max: 64), seller: _seller(call));

/// `sales.fulfil {id, mode?, state?, note?}` (SA-20 to SA-24).
Future<Object?> _fulfil(OpCall call) async => call.write(() => call.engine.sales.fulfil(
  call.text("id"),
  mode: call.args["mode"],
  state: call.args["state"],
  note: call.args["note"],
  seller: _seller(call),
  actor: call.session.accountId,
  device: call.device.id,
));

/// Without [Sales.viewAll], a person only reaches the sales they sold, whatever the client sends
/// (SA-11: the master is the gate).
String? _seller(OpCall call) => _allows(call, Sales.viewAll) ? null : call.session.accountId;

bool _bool(OpCall call, String name) {
  final value = call.args[name];
  if (value != null && value is! bool) throw EngineFailure(ErrorCodes.invalidField, {"field": name});

  return value == true;
}

// ---------------------------------------------------------------- money (`money.md`)

Future<Object?> _moneyCatalog(OpCall call) async => call.engine.finance.catalog();

/// `money.summary {from?}` (M-20): an instant; today in the company's zone without one.
Future<Object?> _moneySummary(OpCall call) async {
  final raw = call.args["from"];
  final from = raw == null ? null : raw is String ? DateTime.tryParse(raw.trim()) : null;
  if (raw != null && from == null) throw const EngineFailure(ErrorCodes.invalidField, {"field": "from"});

  return call.engine.finance.summary(from: from);
}

/// `money.payments.record` (M-1 to M-9).
Future<Object?> _recordPayment(OpCall call) async =>
  call.write(() => call.engine.finance.record(call.args, actor: call.session.accountId, device: call.device.id));

/// `money.payments.void {id, reason?}` (M-8).
Future<Object?> _voidPayment(OpCall call) async => call.write(() => call.engine.finance.voidPayment(
  call.text("id"),
  reason: call.args["reason"],
  actor: call.session.accountId,
  device: call.device.id,
));

/// `money.payments.search {page, size, direction?, concept?, method?, status?}` (M-10).
Future<Object?> _payments(OpCall call) async {
  final (page, size) = _paging(call, MoneyLimits.maxPage, 50);

  return call.engine.finance.search(
    page: page,
    size: size,
    direction: call.args["direction"] == null ? null : call.text("direction", max: 8),
    concept: call.args["concept"] == null ? null : call.text("concept", max: 32),
    method: call.args["method"] == null ? null : call.text("method", max: 32),
    status: call.args["status"] == null ? "all" : call.text("status", max: 16),
  );
}

/// `money.receivables {page, size, open?}` (M-31).
Future<Object?> _receivables(OpCall call) async {
  final (page, size) = _paging(call, MoneyLimits.maxPage, 50);

  return call.engine.finance.receivables(page: page, size: size, open: _bool(call, "open"));
}

/// The account fields sealed with the `payments` key (M-45).
const _sealedMethodArgs = {"holder", "document", "account"};

/// `money.methods.list` (M-45): needs the session's `payments` key (`sealed_locked`).
Future<Object?> _methods(OpCall call) async => call.engine.methods.list(
  call.engine.sealed.key(call.session.sessionId, SealedScope.payments),
  actor: call.session.accountId,
  device: call.device.id,
);

/// `money.methods.rails` (M-40).
Future<Object?> _rails(OpCall call) async => call.engine.methods.rails();

/// `money.methods.create` (M-40 to M-43). Sealing is asynchronous, so the account is checked and
/// sealed before the write.
Future<Object?> _createMethod(OpCall call) async {
  final draft = await call.engine.methods.draftCreate(
    call.args,
    call.engine.sealed.key(call.session.sessionId, SealedScope.payments),
  );

  return call.write(() => call.engine.methods.save(draft, actor: call.session.accountId, device: call.device.id));
}

/// `money.methods.edit {id, …}`: a key left out keeps its value, `null` clears it.
Future<Object?> _editMethod(OpCall call) async {
  final draft = await call.engine.methods.draftEdit(
    call.args,
    call.engine.sealed.key(call.session.sessionId, SealedScope.payments),
  );

  return call.write(() => call.engine.methods.save(draft, actor: call.session.accountId, device: call.device.id));
}

/// `money.methods.remove {id}` (M-44).
Future<Object?> _removeMethod(OpCall call) async => call.write(() => call.engine.methods.remove(
  call.text("id", max: 64),
  actor: call.session.accountId,
  device: call.device.id,
));

Future<Object?> _currencies(OpCall call) async => call.engine.finance.currencies();

/// `money.currencies.save {currency, mode, rate?}` (M-51 to M-53).
Future<Object?> _saveCurrency(OpCall call) async => call.write(() => call.engine.finance.saveCurrency(
  currency: call.text("currency", max: 8),
  mode: call.args["mode"],
  rate: call.args["rate"],
  actor: call.session.accountId,
  device: call.device.id,
));

/// `money.currencies.remove {currency}`.
Future<Object?> _removeCurrency(OpCall call) async => call.write(() => call.engine.finance.removeCurrency(
  call.text("currency", max: 8),
  actor: call.session.accountId,
  device: call.device.id,
));

/// `export.accounting {from, to, datasets, format}` (M-60 to M-65): the file is its asker's.
Future<Object?> _exportAccounting(OpCall call) =>
  call.engine.accounting.run(call.args, actor: call.session.accountId, device: call.device.id);

// ---------------------------------------------------------------- employees (`employees.md`)

/// `employees.list` (E-1): everyone's with `employees`, else only the viewer's card.
Future<Object?> _employees(OpCall call) async =>
  call.engine.employees.list(viewer: call.session.accountId, all: _allows(call, _employeesView));

Future<Object?> _formerEmployees(OpCall call) async => call.engine.employees.former();

/// `employees.detail {id}` (E-3): anyone's with `employees`, else only one's own;
/// the sealed fields with the `hr` key or the person's own.
Future<Object?> _employee(OpCall call) {
  final session = call.session.sessionId;
  final sealed = call.engine.sealed;

  return call.engine.employees.detail(call.text("id", max: 64), (
    account: call.session.accountId,
    session: session,
    all: _allows(call, _employeesView),
    personal: _allows(call, _viewPersonal),
    hrKey: sealed.key(session, SealedScope.hr),
    own: sealed.own(session),
    device: call.device.id,
  ));
}

/// `employees.invite` (E-10). The activation code is answered once: the ledger keeps the answer
/// without it, so a replay doesn't show it again (`employees.reissueActivation` does).
Future<Object?> _invite(OpCall call) async => call.write<Map<String, Object?>>(
  () => call.engine.employees.invite(call.args, actor: call.session.accountId, device: call.device.id),
  keep: (answer) => <String, Object?>{...answer, "activation": null},
);

/// `employees.reissueActivation {id}` (E-11).
Future<Object?> _reissueActivation(OpCall call) async => call.write(
  () => call.engine.employees.reissueActivation(call.text("id", max: 64),
    actor: call.session.accountId, device: call.device.id),
  keep: (_) => const <String, Object?>{},
);

/// `employees.edit {id, KEY: value}` (E-12 to E-16). Sealing is asynchronous, so the change is
/// checked and sealed before the write.
Future<Object?> _editEmployee(OpCall call) async {
  final draft = await call.engine.employees.draftEdit(
    call.args,
    personal: _allows(call, _viewPersonal),
    hrKey: call.engine.sealed.key(call.session.sessionId, SealedScope.hr),
  );

  return call.write(() => call.engine.employees.save(draft, actor: call.session.accountId, device: call.device.id));
}

/// `profile.edit {KEY: value}` (E-13): the session's own person, with no company permission.
Future<Object?> _editOwnProfile(OpCall call) async {
  final draft = await call.engine.employees.draftOwn(call.args, account: call.session.accountId);

  return call.write(() => call.engine.employees.save(draft, actor: call.session.accountId, device: call.device.id));
}

/// `employees.accept {id}`: an invitation to an account that was already active (a rehire).
Future<Object?> _acceptEmployment(OpCall call) async => call.write(() =>
  call.engine.employees.accept(call.text("id", max: 64), account: call.session.accountId, device: call.device.id));

// ---------------------------------------------------------------- permissions (`session.md`)

Future<Object?> _permissions(OpCall call) async => call.engine.permissions.get(call.session.accountId);

Future<Object?> _templates(OpCall call) async => call.engine.permissions.templates();

Future<Object?> _createTemplate(OpCall call) async =>
  call.write(() => call.engine.permissions.createTemplate(call.args, actor: call.session.accountId));

Future<Object?> _editTemplate(OpCall call) async => call.write(() => call.engine.permissions.editTemplate(call.args));

Future<Object?> _removeTemplate(OpCall call) async =>
  call.write(() => call.engine.permissions.removeTemplate(call.args["id"]));

Future<Object?> _members(OpCall call) async => call.engine.permissions.members(call.session.accountId);

Future<Object?> _member(OpCall call) async =>
  call.engine.permissions.member(call.args["username"], viewer: call.session.accountId);

/// `permissions.members.assign {username, template?, permissions?}` (P-6 to P-9).
Future<Object?> _assign(OpCall call) async {
  final answer = call.write(() => call.engine.permissions.assign(
    call.args,
    actor: call.session.accountId,
    mine: call.connection.grant,
    device: call.device.id,
  ));

  await _applyGrant(call, answer["username"]);

  return answer;
}

/// `permissions.members.revoke {username}` (P-6, P-8).
Future<Object?> _revoke(OpCall call) async {
  final answer = call.write(() => call.engine.permissions.revoke(
    call.args["username"],
    actor: call.session.accountId,
    mine: call.connection.grant,
    device: call.device.id,
  ));

  await _applyGrant(call, answer["username"]);

  return answer;
}

/// After a member's write (P-8, P-9): their sessions check the new permissions at once, the
/// sealed scopes they lost are unwrapped, and those they gained are wrapped from the assigner's
/// session when it holds them (otherwise from the next holder's sign in). Also on a replayed
/// command, which changes nothing twice.
Future<void> _applyGrant(OpCall call, Object? username) async {
  final sealed = call.engine.sealed;
  final account = call.engine.permissions.accountOf(username);
  if (account == null) return;

  call.connection.server.regrant(account);
  sealed.unshare(account);
  for (final scope in SealedScope.values) {
    final key = sealed.key(call.session.sessionId, scope);
    if (key != null) await sealed.share(scope, key);
  }
}

Future<Object?> _requests(OpCall call) async => call.engine.permissions.requests(call.session.accountId);

Future<Object?> _request(OpCall call) async =>
  call.write(() => call.engine.permissions.request(call.args, account: call.session.accountId));

/// `page` ≥ 1 and `size` from 1 to [max].
(int, int) _paging(OpCall call, int max, int fallback) {
  final page = _int(call, "page", 1);
  final size = _int(call, "size", fallback);
  if (page < 1) throw const EngineFailure(ErrorCodes.invalidField, {"field": "page"});
  if (size < 1 || size > max) throw const EngineFailure(ErrorCodes.invalidField, {"field": "size"});

  return (page, size);
}
