# Provider restore capacity results

These results summarize the three retained root-run artifacts under `tmp/`. The first two failures are preserved; the continuation run is the only rerun after the fixture and runner update.

## provider-restore-capacity-1

- Session `15959`; source `2ad737d19518650e8a31c463b5c877493756d0d5`.
- Command: `RESTORE_CAPACITY_OUTPUT=tmp/provider-restore-capacity-1 worker/run-restore-capacity.sh`.
- Native/verdict rc `1/1`; one test, one failure. The valid canonical entry was `900265` bytes, but inserting the old whole JSON manifest failed with `SQLITE_TOOBIG`.
- Root receipt records twelve pre/post input hashes equal and the dependency symlink absent.

Raw artifact SHA-256:

| File | SHA-256 |
|---|---|
| `native.rc` | `4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865` |
| `verdict.rc` | `4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865` |
| `result.json` | `5fc0dabf985d6a7ee38aec15168dd4893432edeea820f54db0ffb31d78fb0bab` |
| `root-tool-completion.json` | `72f93596ffeaab8d4e67430d67e0ffff403c2aef3db0c0c087e3d25d0a383a3f` |
| `pre.sha256` | `1dffb91c015dde7499af2830e68e229a1d8ff9d74c251103f5942a7a6649ee04` |
| `post.sha256` | `1dffb91c015dde7499af2830e68e229a1d8ff9d74c251103f5942a7a6649ee04` |
| `source-revision.txt` | `1a8e1a44ca0e349b1eefebb1f3310931f3c8f350d4f9ca1ac7732cfba3be0f29` |
| `runner-inputs.txt` | `faf5c5e5c9958cc14b4a533ec41f8c964fa6e929f3c021e22462c42781a0f015` |
| `stdout.txt` | `8ef923315a20425bca47e614a7af7e71e97ef43fee2508a5b95906b52857db7d` |
| `stderr.txt` | `43d385bcf93dc23e79bda9e8b48673cb3cd73eb48bc7b4dd85c537cdc2923a3e` |

## provider-restore-capacity-2

- Session `31970`; source `d462bef6e993f8eb0e4744b96c8ab55df8e12212`.
- Command: `RESTORE_CAPACITY_OUTPUT=tmp/provider-restore-capacity-2 worker/run-restore-capacity.sh`.
- Native/verdict rc `1/1`; six tests, five passes, one failure. All five authority/legacy tests passed; the capacity test stored a `62`-byte marker but timed out at Vitest's default `5000ms` before final readback was accepted.
- Root receipt records thirteen pre/post input hashes equal, canonical bytes `900265`, marker bytes `62`, and the dependency symlink absent.

Raw artifact SHA-256:

| File | SHA-256 |
|---|---|
| `native.rc` | `4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865` |
| `verdict.rc` | `4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865` |
| `result.json` | `1dda4f0e92cadef0106aea37000a76e7c23fa6958c0db91156682bb26bc18955` |
| `root-tool-completion.json` | `e357d92a2d19554c5d91507d28e1aac7dee71a529c2f9ff280e5ee2d968f85e8` |
| `pre.sha256` | `f7b0c6730807c1a6cb9a61b207aaa468a2c411aea30f7e915f63f18d89205d29` |
| `post.sha256` | `f7b0c6730807c1a6cb9a61b207aaa468a2c411aea30f7e915f63f18d89205d29` |
| `source-revision.txt` | `260959995e83bf416fa526ebe7636cbd6a49d9c0ee4a72b8f2000a8983305816` |
| `runner-inputs.txt` | `faf5c5e5c9958cc14b4a533ec41f8c964fa6e929f3c021e22462c42781a0f015` |
| `stdout.txt` | `7595eeb0a90454fb0002e398ec8c014f3988fbcc8587f1ec805a0100ff6ec6af` |
| `stderr.txt` | `039dbc518b914b959298c5d072ad37cdb19e7f9cb574cf9f3a83034f2d57e406` |

## provider-restore-capacity-3

- Session `49859`; source `d733434d336b0e70a2708ed1acf69080dae42193`.
- Command: `RESTORE_CAPACITY_CONTINUE_OUTPUT=tmp/provider-restore-capacity-3 worker/run-restore-capacity-continue.sh`.
- Native/verdict rc `0/0`; one test passed. The `900265`-byte canonical entry restored with a `62`-byte marker, acquired a lease, appended one entry, performed an actual abort/restart, and verified exact two-entry byte readback. Test time was `179ms`; runner time was `2.82s`.
- Root receipt records twelve pre/post input hashes equal and the dependency symlink absent.

Raw artifact SHA-256:

| File | SHA-256 |
|---|---|
| `native.rc` | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |
| `verdict.rc` | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |
| `result.json` | `3f5ae01963d263c5e22fad156863a3f7c18e9cc73929c43aabfd44a3ab2ff9ab` |
| `root-tool-completion.json` | `7acfba29d4a46df146d4c9167321d0e0252fe876358b1c4eaad1cf74dd36b375` |
| `pre.sha256` | `25383e544fd14fc23e53df42dba9792d66b9681754bbc092dfacb1972eaac623` |
| `post.sha256` | `25383e544fd14fc23e53df42dba9792d66b9681754bbc092dfacb1972eaac623` |
| `source-revision.txt` | `bcadb2237fe7405934fc88113a6cd3575ee10ce7b47dfa7d88a0a89792011899` |
| `runner-inputs.txt` | `faf5c5e5c9958cc14b4a533ec41f8c964fa6e929f3c021e22462c42781a0f015` |
| `stdout.txt` | `6c62e6bbf2d014fb6e38d52d7f06c2289990820c788acf9bf9f45f5935f65349` |
| `stderr.txt` | `0d297af1a9d905215615c8cdbd929771e83b61b539e7da2d6e1c00a2b9f2ec06` |

## Provenance and limits

- Product source for the first failure: `2ad737d19518650e8a31c463b5c877493756d0d5`.
- Product source for the second run: `d462bef6e993f8eb0e4744b96c8ab55df8e12212`.
- Fixture/runner source for the passing continuation: `d733434d336b0e70a2708ed1acf69080dae42193`.
- The continuation used a 20-second per-test timeout and a 180-second outer timeout with the pinned provider dependencies.
- Scope is local Durable Object `RealmStore` SQLite behavior. These runs make no HTTP, cloud, public-grant, or sidecar/provider claim; the retained first two failures were not replayed.
