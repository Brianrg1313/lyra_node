# Module: lyra_node

**Path** `E:/andromeda/frontend/packages/lyra_node` (own git repo, pure Dart, no Flutter)
**Role** The engine that runs on the master (`lyra/app/docs/plan-offline-lan.md` §3, §8): one company, encrypted,
one writer. Phase 2 built storage, keys, oplog, identities, audit and the process lifecycle; phase 3 the LAN server
(TLS, pairing, RPC, events, files, mDNS); phase 4 adds the domains one per release (business so far). Rules come from `lyra/app/docs/offline/specs/*`, never from backend code (plan principle 1).
**Used by** `lyra/app` through the executable only (`LocalServerService`), never as a Dart import.

## Files

- `bin/lyra_node.dart` — the executable: `setup`, `run`, `status`, `stop`, `recover`, `enroll`, `version`; one JSON
  line out, secrets only on stdin. Table of commands in its `///`.
- `lib/lyra_node.dart` — barrel (for `bin/` and tests).
- `lib/src/engine.dart` — `Engine` (`setup` with the owner and the company, `open`, `recover`, `close`, `controlKey`,
  `enrollMaster`, `prepareTransport`; holds `sessions`, `events`, `authority`, `files`, `business`), `OwnerDraft`,
  `DeviceDraft`, `EnrolledDevice`,
  `engineVersion`, `minAppVersion`.
- `lib/src/failure.dart` — `EngineFailure` (a rule's refusal: stable `code` + `data`, no message).
- `lib/src/ids.dart` — `newId()` (UUIDv7).
- `lib/src/crypto/secrets.dart` — `randomBytes`, `wipe`, `constantTimeEquals`, `Argon2Params`, `argon2id`, `subkey` (HKDF).
- `lib/src/crypto/envelope.dart` — `Envelope` (AES-256-GCM, version byte, context as AAD), `EnvelopeError`.
- `lib/src/crypto/keyring.dart` — `KeyringStore` (`keyring.json`: DEK wrapped by KEK and by the recovery key; `create`,
  `unlock`, `recover`, `rewrap`), `Keyring` (DEK in memory, `databaseKey`, `derive`), `UnlockMode`, `KeyringError`.
- `lib/src/crypto/recovery.dart` — `RecoveryKey` (256 bits as 24 BIP-39 words, checksum, 4-letter prefixes).
- `lib/src/crypto/wordlist.dart` — the BIP-39 English list.
- `lib/src/crypto/vault.dart` — `KeyVault` (`platform`), `WindowsVault` (DPAPI, FFI), `MacVault` (`security -i`),
  `LinuxVault` (`secret-tool`), `MemoryVault` (tests).
- `lib/src/storage/store.dart` — `Store` (SQLCipher open with a raw key, refuses a library without cipher; WAL,
  `synchronous=FULL`; `write` = one `BEGIN IMMEDIATE` transaction), `StoreError`.
- `lib/src/storage/migrations.dart` — `Migration`, `migrations`, `migrate` (pre-migration copy, one transaction per step),
  `DatabaseTooNew`.
- `lib/src/storage/migrations/m001_core.dart` — `meta`, `oplog`, `commands`, `audit`, `accounts`, `grants`.
- `lib/src/storage/migrations/m002_network.dart` — `devices`, `sessions`, `refresh_spent`, `events`, `files`.
- `lib/src/storage/migrations/m003_business.dart` — `company`, `site` (one row each; the point in millionths).
- `lib/src/domain/business/business.dart` — `CompanyDraft` (setup, checked before anything is written), `Business`
  (`create`, `profile`, `summary`, `edit` one key, `setLogo`, `site`, `editSite`, `timezone`): `business.md`.
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
- `lib/src/net/rpc.dart` — `RpcConnection` (hello first, gates, rate limit, session binding, event stream), `OpRule`,
  `OpCall` (`write` = change + `commandId` answer in one transaction), `Gate`.
- `lib/src/net/ops.dart` — `opRules`: every op this engine serves, with its gate and permission.
- `lib/src/net/pairing.dart` — `PairingDesk` (the live ticket, SPAKE2 master side, 3 failures void it).
- `lib/src/net/events.dart` — `EventLog` (append inside a write, `publish` after, replay window, `resync_required`),
  `StoredEvent`.
- `lib/src/net/files.dart` — `FileStore` (sealed uploads, type sniffing, `claim` / `release` by a record, orphan sweep),
  `FilePurpose`.
- `lib/src/net/messages.dart` — `Messages` (refusal code → `RpcError` with message and action).
- `lib/src/net/web_bundle.dart` — `WebBundle` (static web build, CSP).
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
  sessions, passphrase mode, browsers, events, files.
- `test/business_test.dart` — the business domain over the LAN: bootstrap, profile edits and their refusals, idempotence,
  `business/changed`, permissions, the site's point, the logo, `catalog.get` (rule numbers in the names).
- `test/discovery_test.dart` — mDNS answers (and a live lookup, tag `network`).
- `test/process_test.dart` — the built executable with the real vault (Windows only, tag `process`).
- `test/browser_e2e_test.dart` — the app's LAN web build in a headless Chrome over DevTools: pairs by code, key in
  IndexedDB, signs in, reloads (`device.prove`), revoked (tag `browser`, needs `LYRA_WEB`).

## Invariants

- Nothing is ever written unencrypted: `Store.open` refuses a SQLite without SQLCipher (`hooks.user_defines` in
  `pubspec.yaml` picks it), and every secret at rest is wrapped (`Envelope`, DPAPI/Keychain/libsecret).
- Only `Keyring` holds the DEK; every key in use is `Keyring.derive(<purpose>)`. A new purpose string is a new key.
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
