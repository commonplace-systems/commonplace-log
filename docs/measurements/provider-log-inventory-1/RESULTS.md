# Provider log inventory results

These are the two retained native attempts for the internal provider log inventory wire fixture. Both runs used the local SQLite-backed Durable Object test pool and selected only `worker/test/realm/log-inventory.workers.test.ts`. The raw output directories remain unchanged under `tmp/provider-log-inventory-1` and `tmp/provider-log-inventory-2`; `RESULTS.json` binds their top-level files, copied-source trees, generated configurations, isolated cache, and runtime input maps by byte count and SHA-256.

## Run 1

Run 1 was session `47526`, with native rc `1` and wrapper verdict `125`. Its Vitest JSON reported four defined assertions, zero passed, zero failed, and four pending. The retained stderr reports failure to pop the isolated storage stack after the first mixed inventory case, with an `.sqlite-shm` path, followed by Vitest warning that tests were still running while producing the JSON report. This is preserved as an incomplete failed run.

The runner used the direct `vitest.workers.config.ts` invocation from authoritative launch source commit `75c507b8f11d3ad04011437018ae60e35560ec1d`, as recorded in the retained `command.json`, `source-pins.json`, and launch checkout. An earlier root completion annotation carried a conflicting full SHA; that annotation is retained in the raw evidence but is not authoritative. The run recorded 25 direct source inputs and 3221 cached runtime files. Runtime membership stayed at 3221 files with no additions or removals, while six shared `.vite/vitest` files changed. The direct PRE/POST equality result is therefore false. Its process group exited with rc 1 and was absent without TERM or KILL.

## Run 2

Run 2 was session `96700`, with native rc `0` and wrapper verdict `0`. The exact result was four defined, four passed, zero failed, and zero pending assertions. The runner used the repository root Vitest project with `--project do`, consumed the authenticated public `404` response body, and generated the project configuration and Vite cache inside the fresh output directory.

Run 2 recorded the same 25 direct source inputs and 3221 cached runtime files. Its copied source directory contains 312 files, including the two generated Vitest configurations; its isolated Vite cache contains seven files totaling 507378 bytes. Runtime membership had no additions, removals, or hash changes, and direct PRE/POST equality was true. The process group exited rc 0 and was absent without TERM or KILL.

The original `.sqlite-shm` failure remains preserved. The changed Vitest project selection, response-body consumption, and private cache passed in Run 2, but that changed harness does not isolate or prove the cause of the original storage teardown failure.

The 25-file direct input maps omit `worker/vitest.config.ts`. For each run, that file was included in the clean current HEAD git archive and is bound by the copied-source directory manifest. This is recorded as an archive/source binding; it is not presented as part of the original direct PRE/POST input count.

The fixture covers internal inventory of mixed normal and restored logs, public-route closure, empty provisioned storage without schema creation, count and UTF-8 metadata bounds, malformed metadata, generation changes after create and commit, and pending/orphan refusal. It makes no claim about cloud deployment, provider authentication, account activation, public grants, or production storage RPC.

The complete artifact hashes, exact argv, native records, process-group records, runtime membership differences, and directory-manifest serialization are in [`RESULTS.json`](./RESULTS.json).
