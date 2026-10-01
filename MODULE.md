# Module: lyra_node

**Path** `E:/andromeda/frontend/packages/lyra_node` (own git repo, pure Dart, no Flutter)
**Role** The engine that runs on the master (`lyra/app/docs/plan-offline-lan.md` §3, §8): one company, encrypted,
one writer. Phase 2 built storage, keys, oplog, identities, audit and the process lifecycle; phase 3 the LAN server
(TLS, pairing, RPC, events, files, mDNS); phase 4 adds the domains one per release (business, inventory and stock, import, POS, sales, finance with its accounts and the accounting export so far). Rules come from `lyra/app/docs/offline/specs/*`, never from backend code (plan principle 1).
**Used by** `lyra/app` through the executable only (`LocalServerService`), never as a Dart import.

## Files

- `bin/lyra_node.dart` — the executable: `setup`, `run`, `status`, `stop`, `recover`, `enroll`, `version`; one JSON
  line out, secrets only on stdin. Table of commands in its `///`.
- `lib/lyra_node.dart` — barrel (for `bin/` and tests).
- `lib/src/engine.dart` — `Engine` (`setup` with the owner and the company, `open`, `recover`, `close`, `controlKey`,
  `enrollMaster`, `prepareTransport`; holds `sessions`, `events`, `authority`, `files`, `business`, `inventory`,
  `stock`, `pos`, `sales`, `finance`, `methods`, `accounting`, `sealed`), `OwnerDraft`,
  `DeviceDraft`, `EnrolledDevice`,
  `engineVersion`, `minAppVersion`.
- `lib/src/failure.dart` — `EngineFailure` (a rule's refusal: stable `code` + `data`, no message).
- `lib/src/ids.dart` — `newId()` (UUIDv7, monotonic within the engine: same-millisecond ids keep their order).
- `lib/src/crypto/secrets.dart` — `randomBytes`, `wipe`, `constantTimeEquals`, `Argon2Params`, `argon2id`, `subkey` (HKDF).
- `lib/src/crypto/envelope.dart` — `Envelope` (AES-256-GCM, version byte, context as AAD), `EnvelopeError`.
- `lib/src/crypto/keyring.dart` — `KeyringStore` (`keyring.json`: DEK wrapped by KEK and by the recovery key; `create`,
  `unlock`, `recover`, `rewrap`), `Keyring` (DEK in memory, `databaseKey`, `derive`), `UnlockMode`, `KeyringError`.
- `lib/src/crypto/recovery.dart` — `RecoveryKey` (256 bits as 24 BIP-39 words, checksum, 4-letter prefixes).
- `lib/src/crypto/wordlist.dart` — the BIP-39 English list.
- `lib/src/crypto/sealed.dart` — `SealedKeys` (plan §6.3: an X25519 pair per account sealed by its password, each
  scope's key wrapped to its holders and to the recovery key, a session's keys sealed by its refresh token;
  `signedIn`, `refreshed`, `key`, `rewrap` + `save`, `setRecovery`, `recover`, `sealJson` / `openJson`), `SealedScope`
  (`hr`, `payments`), `AccountKeyWrap`.
- `lib/src/crypto/vault.dart` — `KeyVault` (`platform`), `WindowsVault` (DPAPI, FFI), `MacVault` (`security -i`),
  `LinuxVault` (`secret-tool`), `MemoryVault` (tests).
- `lib/src/storage/store.dart` — `Store` (SQLCipher open with a raw key, refuses a library without cipher; WAL,
  `synchronous=FULL`; `write` = one `BEGIN IMMEDIATE` transaction; SQL `fold(x)`), `StoreError`, `fold` (case and
  accents off, the text search).
- `lib/src/storage/migrations.dart` — `Migration`, `migrations`, `migrate` (pre-migration copy, one transaction per step),
  `DatabaseTooNew`.
- `lib/src/storage/migrations/m001_core.dart` — `meta`, `oplog`, `commands`, `audit`, `accounts`, `grants`.
- `lib/src/storage/migrations/m002_network.dart` — `devices`, `sessions`, `refresh_spent`, `events`, `files`.
- `lib/src/storage/migrations/m003_business.dart` — `company`, `site` (one row each; the point in millionths).
- `lib/src/domain/business/business.dart` — `CompanyDraft` (setup, checked before anything is written), `Business`
  (`create`, `profile`, `summary`, `edit` one key, `setLogo`, `site`, `editSite`, `timezone`, `language`, `currency`,
  `decimals`): `business.md`.
- `lib/src/domain/business/zones.dart` — `Zones` (the IANA database compiled in: `known`, `dayOf` a zone's day in UTC,
  `startOf` a calendar day, `local` an instant as ISO with the zone's offset).
- `lib/src/storage/migrations/m004_inventory.dart` — `inventory_tables`, `inventory_fields`, `inventory_records` (cells as
  one JSON object), `stock_movements`, `stock_balances`, `stock_holds`.
- `lib/src/storage/migrations/m005_pos.dart` — `pos_invoices`, `pos_lines` (a line's id is its hold's), `pos_series`.
- `lib/src/storage/migrations/m006_money.dart` — `money_payments` (never edited: voided in place), `money_currencies`
  (one row per currency ever added, `active`).
- `lib/src/storage/migrations/m007_sealed.dart` — `account_keys`, `sealed_keys`, `sessions.sealed`.
- `lib/src/storage/migrations/m008_money_methods.dart` — `money_methods` (`holder`, `document`, `account` in one sealed
  blob).
- `lib/src/domain/inventory/inventory.dart` — `Inventory`: tables (templates, primary flag), fields (dense positions,
  re-typing, width alone), records (checked cells, SKU, counter, text search), images; reads for the ledger
  (`product`, `primaryTable`): `inventory.md`.
- `lib/src/domain/inventory/importing.dart` — part of `inventory.dart`: `InventoryImport` (`importStructure` with its
  `table/normalizing` and `table/ready`, `importRecords` answering the opening balances, `normalize`; I-40 to I-47).
- `lib/src/domain/inventory/spreadsheet.dart` — `Sheet` (`read` off the isolate: header row, names, limits), `Csv`
  (encodings, separator, quotes), `Xlsx` (first sheet by events: shared/inline strings, date styles).
- `lib/src/domain/inventory/typing.dart` — `Typing` (I-43: header keywords, value rules, one title/stock; `cell`
  reads a value as a type with the language's number and date marks; `units`, `gtin`).
- `lib/src/domain/inventory/cells.dart` — `Cells` (what a cell stores per field type, I-21; `read` for re-typing).
- `lib/src/domain/stock/stock.dart` — `Stock` (`move` with the projection, manual holds and a ticket line's hold,
  `held`, `balanceOf`, `history`, `summary`, `rebuild`): `stock.md`.
- `lib/src/domain/pos/pos.dart` — `Pos` (`summary`, `methods`, `catalog` by field type and cursor, `open` with the
  device's code, `line`, `close`, `cancel`, `list`; every figure computed from frozen lines, `lineTotal`): `pos.md`.
- `lib/src/domain/pos/money.dart` — `Money` (minor units, percents as text, half away from zero, in integers).
- `lib/src/domain/sales/sales.dart` — `Sales` (`catalog`, `list` paged in SQL by the measured stage, `row`, `detail`,
  `fulfil`; `measure` and `announce` of `sale/progress`, which `Pos` calls on its writes): `sales.md`.
- `lib/src/domain/money/finance.dart` — `Finance` (`catalog`, `record` and `voidPayment` (audited), `search` with the
  filter's totals, `summary` beside the closed tickets, `receivables` measured from settlements, `currencies` with
  custom rates; `credit` off; a payment names an account): `money.md`.
- `lib/src/domain/money/methods.dart` — `MoneyMethods` (`rails`, `list` (sealed, audited), `draftCreate` / `draftEdit`
  checked and sealed before `save`, `remove`), `MethodDraft`: `money.md` money.method.
- `lib/src/domain/export/accounting.dart` — `Accounting` (`run`: `export.accounting`, M-60 to M-65; the window in the
  company's zone, the row ceiling, the datasets and their `*Columns`, the file kept for its asker, the audit entry).
- `lib/src/domain/export/writers.dart` — `ExportFormat` (`csv` zipped, `xlsx`), `Dataset`, `Decimal` (minor units as
  text), `CsvWriter` (BOM, separator by decimal mark, formula guard), `Workbook` (one sheet per dataset, inline text).
- `docs/export.md` — the export's columns, window and formats: the contract with the accounting software.
- `lib/src/domain/money/rails.dart` — `Rails` (the cloud's rails, requirement sheets and bank, document and network
  lists as of 2026-09; `offered`, `available`, `options`, `sheet`, `format`, `document`), `RailField`.
- `lib/src/oplog/hlc.dart` — `Hlc` (packed, sortable), `HlcClock` (never backwards, `maxDrift`), `ClockDrift`.
- `lib/src/oplog/oplog.dart` — `Oplog` (`append` inside the write, `since`, `lastSeq`, `lastHlc`), `OplogEntry`.
- `lib/src/oplog/commands.dart` — `CommandLedger` (`commandId` idempotence, 30 days), `CommandReused`.
- `lib/src/audit/audit_log.dart` — `AuditLog` (hash-chained, `append`, `verify`, `list`), `AuditEntry`, `AuditKinds`.
- `lib/src/identity/passwords.dart` — `PasswordHasher` (Argon2id PHC strings, `needsRehash`).
- `lib/src/identity/accounts.dart` — `Accounts` (`createOwner`, `card` (the bootstrap's person), `verifyPassword` with
  lockout, `newPasswordHash` + `setPassword`, `usesPassword`), `Account`, `AccountStatus`.
- `lib/src/identity/devices.dart` — `Devices` (`enroll`, `rename`, `revoke`, `touch`, `byFingerprint`, `master`, `codeFor`),
  `Device`, `DeviceKind` (`master`, `native`, `web`).
- `lib/src/identity/sessions.dart` — `Sessions` (access tokens in memory, rotated refresh tokens, reuse ends the session),
  `SessionTokens`, `SessionGrant`, `SessionScope`.
- `lib/src/identity/permissions.dart` — `Permissions.allows` (`session.md` P-1).
- `lib/src/net/x509.dart` — `X509` (the two roots of the installation CA, server and device certificates), `Certificate`.
- `lib/src/net/tls.dart` — `LocalAddresses`, `Authority` (CA key and roots in `meta`, issues), `Transport`
  (`transport.json`, sealed with a control-key subkey: what TLS needs while locked).
- `lib/src/net/server.dart` — `LanServer` (TLS 1.3 only; `/rpc`, `/pair`, `/f`, web bundle; revoked certificates and
  foreign `Origin`s refused before the upgrade; locked mode).
- `lib/src/net/rpc.dart` — `RpcConnection` (hello first, gates, rate limit, session binding, event stream), `OpRule`
  (`sealedArgs` kept out of the ledger's hash), `OpCall` (`write` = change + `commandId` answer in one transaction), `Gate`.
- `lib/src/net/ops.dart` — `opRules`: every op this engine serves, with its gate and permission.
- `lib/src/net/pairing.dart` — `PairingDesk` (the live ticket, SPAKE2 master side, 3 failures void it).
- `lib/src/net/events.dart` — `EventLog` (append inside a write for a permission or `anyOf` several, or for an
  `owner` and those holding `overrides`; `publish` after, replay window, `resync_required`), `StoredEvent`.
- `lib/src/net/files.dart` — `FileStore` (sealed uploads, type sniffing, a sealed 320 px thumbnail of each image made off
  the isolate, `get` with `size` (a product image also for `pos.view`), `claim` / `release` by a record, `once` /
  `discard` for an import, `keep` an export for its asker (expires after `orphanAge`), orphan sweep),
  `FilePurpose`.
- `lib/src/net/messages.dart` — `Messages` (refusal code → `RpcError` with message and action).
- `lib/src/net/web_bundle.dart` — `WebBundle` (static web build, CSP, `marker` written into its HTML).
- `lib/src/net/discovery.dart` — `MdnsResponder` (`_lyra._tcp.local`).
- `lib/src/process/paths.dart` — `NodePaths` (data folder per OS and its files).
- `lib/src/process/lock.dart` — `InstanceLock` (exclusive OS lock, one engine per folder).
- `lib/src/process/control.dart` — `EngineStatusFile` (`engine.state.json`, HMAC-signed), `EnginePhase`, `ControlChannel`
  (signed stop requests in `control/`).
- `lib/src/process/runner.dart` — `NodeRunner` (lock → state → unlock → wait for stop), `ExitCodes`.
- `lib/src/process/status.dart` — `readStatus`, `stopEngine`, `NodeStatus` (the app's side, run through the CLI).
- `lib/src/process/engine_log.dart` — `EngineLog` (`logs/engine.log`, rotated; no secrets, no company data).
- `test/support.dart` — fast Argon2 params, temp data folders, `setUpMaster`.
- `test/support/launch_detached.dart` — plays the app: starts the engine detached (free port) and exits.
- `test/net_support.dart` — `TestMaster` (a master on loopback with its app enrolled), browser and attacker helpers.
- `test/crypto_test.dart`, `keyring_test.dart`, `storage_test.dart`, `oplog_test.dart`, `engine_test.dart` — units.
- `test/net_test.dart` — the LAN server with real TLS clients: handshake, pairing, man in the middle, revocation,
  sessions, passphrase mode, browsers (the page marked as a master's), events, files.
- `test/business_test.dart` — the business domain over the LAN: bootstrap, profile edits and their refusals, idempotence,
  `business/changed`, permissions, the site's point, the logo, `catalog.get` (rule numbers in the names).
- `test/inventory_test.dart` — inventory and stock over the LAN: tables, templates and the primary flag, fields and
  positions, cells and SKUs, search, images and thumbnails, movements, holds, replays, events, history, summary.
- `test/pos_test.dart` — money and zones; the counter over the LAN: catalogue by type, codes per device, lines and
  holds, refusals and their permissions, close and cancel, untracked products, I-4, events to a cashier.
- `test/sales_test.dart` — the sales board over the LAN: catalogue, sections and order, the handover and its
  refusals, the detail of an invoice and of a ticket, `sales.view_all` on the list, detail, write and notices.
- `test/finance_test.dart` — money over the LAN: the catalogue offline, recording and voiding with their refusals and
  the audit, the history's order and totals, the summary beside the register, receivables, currencies, permissions.
- `test/methods_test.dart` — the sealed keys (first holder, recovery wrap, refresh and restart, grants, password
  change) and the accounts over the LAN: rails per country, sheets, nothing sealed in clear at rest (rows, ledger,
  oplog), refusals, edits, payments naming one, a session without the key, permissions.
- `test/export_test.dart` — the accounting export: the writers (amounts, CSV quoting and formula guard), both formats
  downloaded over the LAN and read back, the window, refusals, the audit, the file only its asker reads for an hour.
- `test/import_test.dart` — importing: `.csv` / `.xlsx` reading, the typing rules, both steps over the LAN with their
  events and opening balances, normalizing, limits.
- `test/discovery_test.dart` — mDNS answers (and a live lookup, tag `network`).
- `test/process_test.dart` — the built executable with the real vault (Windows only, tag `process`).
- `test/browser_e2e_test.dart` — the app's LAN web build in a headless Chrome over DevTools: pairs by code, key in
  IndexedDB, signs in, reloads (`device.prove`), revoked (tag `browser`, needs `LYRA_WEB`).

## Invariants

- Nothing is ever written unencrypted: `Store.open` refuses a SQLite without SQLCipher (`hooks.user_defines` in
  `pubspec.yaml` picks it), and every secret at rest is wrapped (`Envelope`, DPAPI/Keychain/libsecret).
- Only `Keyring` holds the DEK; every key in use is `Keyring.derive(<purpose>)`. A new purpose string is a new key.
  The sealed keys are the exception on purpose: they are **not** derived from the DEK, so the DEK alone can't open
  them (plan §6.3). A sealed value is never written in clear anywhere: not in the oplog, not in a write's kept
  answer (`OpRule.sealedArgs`).
- A change, its oplog entry, its audit entry and its `commandId` answer are written in the **same** `Store.write`
  (a nested `write` joins the running one; write ops commit through `OpCall.write`).
- Migrations are forward only: a released one is never edited.
- The engine never starts by itself (plan D4): nothing here installs a service, login item or scheduled task.
- Lifecycle control (status, stop) is files in the data folder signed with the control key (vault); the signed state
  file is how the app knows the process is ours. Everything else, the master's own app included, goes through
  `LanServer` with mutual TLS.
- Nothing is served or accepted without TLS 1.3 and a verified peer: there is no plaintext listener, and every `/rpc`
  op past `hello` needs a paired device (client certificate, or `device.prove` for a browser).
- Native clients pin the unconstrained root (`Authority.pinned`); only the name-constrained root
  (`Authority.browser`) may go into an OS trust store. Both have one key and name, so every issued certificate
  chains to both.
- `engine.unlock` and `pairing.start` are accepted only from the master device named in `transport.json`.

## Commands

```
dart analyze                          # must report "No issues found!"
dart test                             # all (process tests build the executable first)
dart test -x process                  # without the slow process tests
dart build cli                        # build/cli/<os>_<arch>/bundle/{bin/lyra_node(.exe), lib/sqlcipher.*}
```
