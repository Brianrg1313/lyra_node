import 'dart:convert';

import 'package:crypto/crypto.dart' show sha1;
import 'package:lyra_protocol/lyra_protocol.dart';

import '../engine.dart';
import '../failure.dart';
import '../identity/devices.dart';
import '../identity/permissions.dart';
import '../audit/audit_log.dart';
import '../crypto/sealed.dart';
import '../domain/inventory/inventory.dart';
import '../domain/inventory/spreadsheet.dart';
import '../domain/money/finance.dart';
import '../domain/sales/sales.dart';
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
  Ops.businessProfile.name: const OpRule(_profile, permission: _businessView),
  Ops.businessEdit.name: const OpRule(_editProfile, permission: "business.settings.edit"),
  Ops.businessSetLogo.name: const OpRule(_setLogo, permission: "business.settings.edit_logo"),
  Ops.businessSiteGet.name: const OpRule(_site, permission: _businessView),
  Ops.businessSiteEdit.name: const OpRule(_editSite, permission: "business.settings.edit"),
  Ops.inventoryTablesList.name: const OpRule(_tables, permission: _inventoryView),
  Ops.inventoryTablesCreate.name: const OpRule(_createTable, permission: "inventory.create_table"),
  Ops.inventoryTablesEdit.name: const OpRule(_editTable, permission: "inventory.edit_table"),
  Ops.inventoryTablesDelete.name: const OpRule(_deleteTable, permission: "inventory.delete_table"),
  Ops.inventoryTablesStructure.name: const OpRule(_structure, permission: _inventoryView),
  Ops.inventoryTablesDetails.name: const OpRule(_details, permission: _inventoryView),
  Ops.inventoryFieldsCreate.name: const OpRule(_createField, permission: _editColumns),
  // A column's width alone is anyone's who opens the table (I-17); the handler asks for more.
  Ops.inventoryFieldsEdit.name: const OpRule(_editField, permission: _inventoryView),
  Ops.inventoryFieldsDelete.name: const OpRule(_deleteField, permission: _editColumns),
  Ops.inventoryRecordsList.name: const OpRule(_records, permission: _inventoryView),
  Ops.inventoryRecordsCreate.name: const OpRule(_createRecord, permission: _editRecords),
  Ops.inventoryRecordsEdit.name: const OpRule(_editRecord, permission: _editRecords),
  Ops.inventoryRecordsDelete.name: const OpRule(_deleteRecord, permission: _editRecords),
  Ops.inventoryImagesAdd.name: const OpRule(_addImage, permission: _editRecords),
  Ops.inventoryImagesRemove.name: const OpRule(_removeImage, permission: _editRecords),
  Ops.inventoryImportStructure.name: const OpRule(_importStructure, permission: "inventory.import"),
  Ops.inventoryImportRecords.name: const OpRule(_importRecords, permission: "inventory.import"),
  Ops.inventoryTablesNormalize.name: const OpRule(_normalize, permission: _editColumns),
  Ops.stockMove.name: const OpRule(_move, permission: "inventory.move_stock"),
  Ops.stockHistory.name: const OpRule(_history, permission: _inventoryView),
  Ops.stockSummary.name: const OpRule(_summary, permission: _inventoryView),
  Ops.posSummary.name: const OpRule(_posSummary, permission: _posView),
  Ops.posCatalog.name: const OpRule(_posCatalog, permission: _posView),
  Ops.posMethods.name: const OpRule(_posMethods, permission: _posView),
  // A typed-in charge and a changed rate need more (`pos.md`, ops): the handler asks.
  Ops.posInvoicesOpen.name: const OpRule(_openInvoice, permission: "pos.sell"),
  Ops.posInvoicesLine.name: const OpRule(_writeLine, permission: "pos.sell"),
  Ops.posInvoicesClose.name: const OpRule(_closeInvoice, permission: "pos.checkout"),
  Ops.posInvoicesCancel.name: const OpRule(_cancelInvoice, permission: "pos.cancel_ticket"),
  Ops.posInvoicesList.name: const OpRule(_openInvoices, permission: _posView),
  Ops.salesList.name: const OpRule(_sales, permission: _salesView),
  Ops.salesCatalog.name: const OpRule(_salesCatalog, permission: _salesView),
  Ops.salesDetail.name: const OpRule(_saleDetail, permission: _salesView),
  Ops.salesFulfil.name: const OpRule(_fulfil, permission: "sales.fulfil"),
  Ops.moneyCatalog.name: const OpRule(_moneyCatalog, permission: "finance.view"),
  Ops.moneySummary.name: const OpRule(_moneySummary, permission: "finance.overview.view"),
  // `finance.payments.record`, or `finance.receivables.collect` for a concept that settles (M-7).
  Ops.moneyPaymentsRecord.name: const OpRule(_recordPayment),
  Ops.moneyPaymentsVoid.name: const OpRule(_voidPayment, permission: "finance.payments.void"),
  Ops.moneyPaymentsSearch.name: const OpRule(_payments, permission: "finance.payments.view"),
  Ops.moneyReceivables.name: const OpRule(_receivables, permission: "finance.receivables.view"),
  Ops.moneyMethodsList.name: const OpRule(_methods, permission: _methodsView),
  Ops.moneyMethodsRails.name: const OpRule(_rails, permission: _methodsView),
  Ops.moneyMethodsCreate.name:
    const OpRule(_createMethod, permission: "finance.methods.create", sealedArgs: _sealedMethodArgs),
  Ops.moneyMethodsEdit.name: const OpRule(_editMethod, permission: "finance.methods.edit", sealedArgs: _sealedMethodArgs),
  Ops.moneyMethodsRemove.name: const OpRule(_removeMethod, permission: "finance.methods.delete"),
  Ops.moneyCurrenciesGet.name: const OpRule(_currencies, permission: _methodsView),
  Ops.moneyCurrenciesSave.name: const OpRule(_saveCurrency, permission: _manageCurrencies),
  Ops.moneyCurrenciesRemove.name: const OpRule(_removeCurrency, permission: _manageCurrencies),
};

const _businessView = "business.view";
const _inventoryView = "inventory.view";
const _editColumns = "inventory.edit_columns";
const _editRecords = "inventory.edit_records";
const _posView = "pos.view";
const _salesView = "sales.view";
const _manageCurrencies = "finance.methods.manage_currencies";
const _methodsView = "finance.methods.view";

/// `docs/app-areas.json`, area `local_server`.
const _devicesPermission = "local_server.devices";

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

  call.connection.bind(token, grant, account.grants);
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

/// `auth.refresh {refreshToken}` (S-21).
Future<Object?> _refresh(OpCall call) async {
  final engine = call.engine;
  final previous = call.text("refreshToken");
  final tokens = engine.sessions.refresh(previous, deviceId: call.device.id);
  final account = engine.accounts.byId(engine.sessions.accountOf(tokens.sessionId) ?? "");

  // The session's sealed keys move to the new token (and come back after a restart).
  await engine.sealed.refreshed(
    tokens.sessionId,
    grants: account?.grants ?? const {},
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
/// `addresses` and `port` are where a browser then opens the web build.
Future<Object?> _browserCa(OpCall call) async {
  final root = call.engine.authority.browser;
  final server = call.connection.server;

  return {
    "addresses": server.transport.addresses.where((address) => address != "127.0.0.1" && address != "::1").toList(),
    "port": server.port,
    "certificate": base64.encode(root.der),
    "fingerprint": root.fingerprint,
    "thumbprint": sha1.convert(root.der).toString(),
  };
}

/// `session.bootstrap` (`session.md`): what `/init` answers in the cloud, for this master's one
/// company (S-30), with no tasks (S-31) and the bundled catalogues (S-32).
Future<Object?> _bootstrap(OpCall call) async {
  final engine = call.engine;
  final business = engine.business;

  return {
    "client": engine.accounts.card(call.session.accountId),
    "businesses": [business.summary()],
    "permissions": {business.id: [...call.connection.grants]..sort()},
    "tasks": const <Object?>[],
    "catalogs": {
      "version": Catalogs.version,
      Catalogs.countries: Catalogs.countryRows,
      Catalogs.currencies: Catalogs.currencyRows,
    },
    "deployment": {
      "mode": "local",
      "instanceId": engine.instanceId,
      "engine": engineVersion,
      "timezone": business.timezone,
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

bool _isOwner(OpCall call) => call.connection.grants.contains(Permissions.all);

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

Future<Object?> _site(OpCall call) async => call.engine.business.site();

/// `business.site.edit {changed keys}` (B-10 to B-12).
Future<Object?> _editSite(OpCall call) async => call.write(() =>
  call.engine.business.editSite(call.args, actor: call.session.accountId, device: call.device.id));

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

/// `inventory.fields.edit`: anything past the width needs `inventory.edit_columns` (I-17).
Future<Object?> _editField(OpCall call) async {
  final inventory = call.engine.inventory;
  if (!inventory.onlyWidth(call.args) && !Permissions.allows(call.connection.grants, _editColumns)) {
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
Future<Object?> _move(OpCall call) async => call.write(() => call.engine.stock.move(
  operation: call.text("operation", max: 16),
  tableId: call.text("tableId"),
  productId: call.text("productId"),
  quantity: call.args["quantity"],
  reason: call.args["reason"],
  note: call.args["note"],
  actor: call.session.accountId,
  device: call.device.id,
  commandId: call.request.commandId,
));

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
  need: (permission) {
    if (!Permissions.allows(call.connection.grants, permission)) throw const EngineFailure(ErrorCodes.forbidden);
  },
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
/// its own section, whose view permission the session must hold.
Future<Object?> _sales(OpCall call) async {
  final stage = call.args["stage"] == null ? null : call.text("stage", max: 32);
  final kind = stage == null ? null : SaleStages.kinds[stage];
  if (stage != null && kind == null) throw const EngineFailure(ErrorCodes.invalidField, {"field": "stage"});

  final section = kind?.$1 ?? call.text("section", max: 16);
  if (section != SaleStages.process && section != SaleStages.done) {
    throw const EngineFailure(ErrorCodes.invalidField, {"field": "section"});
  }
  if (!Permissions.allows(call.connection.grants, "sales.$section.view")) {
    throw const EngineFailure(ErrorCodes.forbidden);
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

/// Without `sales.view_all`, a person only reaches the sales they sold, whatever the client sends
/// (SA-11: the master is the gate).
String? _seller(OpCall call) =>
  Permissions.allows(call.connection.grants, Sales.viewAll) ? null : call.session.accountId;

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

/// `money.payments.record` (M-1 to M-9): which permission it needs depends on the concept.
Future<Object?> _recordPayment(OpCall call) async {
  final concept = Finance.conceptOf(call.args["concept"]);
  final permission = MoneyConcepts.kinds[concept]!.$3 ? "finance.receivables.collect" : "finance.payments.record";
  if (!Permissions.allows(call.connection.grants, permission)) throw const EngineFailure(ErrorCodes.forbidden);

  return call.write(() => call.engine.finance.record(call.args, actor: call.session.accountId, device: call.device.id));
}

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

/// `page` ≥ 1 and `size` from 1 to [max].
(int, int) _paging(OpCall call, int max, int fallback) {
  final page = _int(call, "page", 1);
  final size = _int(call, "size", fallback);
  if (page < 1) throw const EngineFailure(ErrorCodes.invalidField, {"field": "page"});
  if (size < 1 || size > max) throw const EngineFailure(ErrorCodes.invalidField, {"field": "size"});

  return (page, size);
}
