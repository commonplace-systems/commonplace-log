# Provider-local restore bundle results

This is the retained native run for the internal `RealmStore` bundle primitive. The fixtures use synthetic local Durable Objects; they do not exercise a real app archive, provider authentication, HTTP, cloud deployment, provisioning, or app projection activation.

## provider-restore-bundle-1

- Session `21930`; source `11f8e63dad0052dea12f227515af2ffe68a8c5f8`.
- Recorded command: `env RESTORE_BUNDLE_OUTPUT=/home/jes/commonplace-log-restore-bundle/tmp/provider-restore-bundle-1 bash worker/run-restore-bundle.sh`.
- Native/verdict rc `0/0`; 20 tests passed across four files in `5.62s`: store `10`, authority/legacy `5`, capacity `1`, bundle `4`.
- Bundle coverage includes sorted two-log inventory and 1-log batching, pending fences on every normal API plus standalone restore, abort/restart resume, exact bundle and per-log digest validation, completed replay with a legitimate subsequent writer append and extra normal log, preexisting/orphan/malformed/size/count/order refusals, aggregate 16 MiB validation, injected second-row rollback, missing completed log/marker refusal, and unchanged `realm_meta`.
- Capacity coverage restored a `900265`-byte canonical entry with a `62`-byte compact marker and exact two-entry readback after actual abort/restart.
- Root receipt records 15 pre/post input hashes equal and temporary dependency symlink removal. `stderr.txt` is retained and contains expected workerd abort/restart diagnostics plus dependency sourcemap warnings; it is not empty.

Raw artifact SHA-256:

| File | SHA-256 |
|---|---|
| `native.rc` | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |
| `verdict.rc` | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |
| `result.json` | `f74f74d2fdf4e8a9b68bfa4200fa92a94bd40b35fd649a89a827dd1a1627dea2` |
| `root-tool-completion.json` | `564d8280099f3494fd7602463c6a4d07cc5a8123c9cef391e4a39ffcac0a3c52` |
| `pre.sha256` | `7d258d479794796d45f9314aef991568b1ff0b3dd95dc1ab33f365737aefc471` |
| `post.sha256` | `7d258d479794796d45f9314aef991568b1ff0b3dd95dc1ab33f365737aefc471` |
| `source-revision.txt` | `550818b1486ef0d2013aef4da943e0c2306bc6b56c7da560d01c4aa2b6cd83b3` |
| `runner-inputs.txt` | `faf5c5e5c9958cc14b4a533ec41f8c964fa6e929f3c021e22462c42781a0f015` |
| `stdout.txt` | `ebfb64a1aaffad93ee42eca78f799e56f9b66653bc449ecff42d864065377cbb` |
| `stderr.txt` | `41d75f7321303290d7fc3c234b17a7e9caaf39b30bc15070f96b402bc70d1edf` |

## Limits

- Bundle limits are 64 logs, 4096 entries per log, 16 MiB aggregate canonical bytes, and a 1–64 log batch parameter.
- The runner uses the pinned dependencies at `/home/jes/commonplace-log/worker/node_modules` and a 270-second outer timeout.
- The result covers local SQLite transaction, restart, fencing, digest, and rollback behavior only. It makes no HTTP, cloud, provisioning, provider-auth, public-grant, or app-activation claim.
