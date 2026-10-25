# lyra_node

The Lyra engine. It runs on a company's master device in offline/LAN mode: it stores one
company encrypted (SQLCipher), keeps the keys, the oplog and the audit trail, holds the accounts
and permissions, serves the company to paired devices on the LAN (TLS 1.3, pairing, RPC, events,
files, mDNS) and syncs with the cloud. Pure Dart, no Flutter.

> **Proprietary software.** All rights reserved — see [LICENSE](LICENSE). No use, copying or
> distribution is permitted without written authorization.

The Lyra app never imports this package: it runs the built executable and talks to it over the
LAN protocol (`lyra_protocol`).

## Layout

| Path | What it is |
|---|---|
| `bin/lyra_node.dart` | The executable: `setup`, `run`, `status`, `stop`, `recover`, `enroll`, `version`. |
| `lib/src/engine.dart` | `Engine`, the entry point that holds every part. |
| `lib/src/storage/` | Encrypted store and forward-only migrations. |
| `lib/src/crypto/` | Keys, envelopes, sealed values. |
| `lib/src/identity/`, `audit/`, `oplog/` | Accounts and grants, audit trail, operation log. |
| `lib/src/net/` | LAN server: TLS, certificates, pairing, RPC, discovery. |
| `lib/src/domain/` | One folder per business domain (business, inventory, POS, sales, finance, …). |
| `lib/src/sync/` | Edge sync with the cloud. |
| `lib/src/process/` | Process lifecycle and signed control files. |
| `docs/` | Engine-specific notes. |
| `test/` | Unit, contract, process, network and browser tests. |

[`MODULE.md`](MODULE.md) lists every file and the invariants.

## Requirements

- Dart SDK `^3.10.0`
- `lyra_protocol` checked out next to this repository (`../lyra_protocol`)
- SQLCipher is selected through `hooks.user_defines` in `pubspec.yaml`; the store refuses to open
  a plain SQLite library.

## Development

```sh
dart pub get
dart analyze           # must report "No issues found!"
dart test              # all (process tests build the executable first)
dart test -x process   # without the slow process tests
dart build cli         # build/cli/<os>_<arch>/bundle/
```

Test tags (`dart_test.yaml`): `process` builds and runs the real executable (Windows), `network`
uses real multicast, `browser` drives Chrome against the app's LAN web build (`LYRA_WEB`).

## Security

- Nothing is written unencrypted and nothing is served without TLS 1.3 and a verified peer; see
  the invariants in [`MODULE.md`](MODULE.md).
- Never commit a data folder, database, key, certificate or vault: `.gitignore` keeps them out.
  Tests create their own in temporary directories, and every credential in `test/` is a fixture.
- Report vulnerabilities privately to the maintainer; do not open public issues for them.

## License

Proprietary. Copyright (c) 2025-2026 David. All rights reserved. See [LICENSE](LICENSE).
