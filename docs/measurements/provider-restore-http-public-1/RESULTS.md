# Public restore HTTP run 1

The retained run is **incomplete**, with verdict `125`. Both selected Vitest children returned `0`: the three public `SELF` ingress cases passed, and the selected authorization contract passed. Four remaining `restore-wire` cases were filtered and skipped. Both owned process groups exited normally and were absent; no TERM, KILL, timeout, or runner signal occurred.

The execution audit failed only because two files in the shared pinned Vitest runtime changed:

- `node_modules/.vite/vitest/da39a3ee5e6b4b0d3255bfef95601890afd80709/results.json`
- `node_modules/.vite/vitest/eadcd9bd2a09c75aef04954e6799e50278ee124a/deps_ssr/_metadata.json`

Runtime membership stayed equal and provider source, archived executed source, and tool hashes stayed equal. The changed cache files are recorded with pre/post hashes in `RESULTS.json`; the raw output tree is bound by `output-manifest-1.json`. This run therefore records assertion evidence, not a clean execution-audit pass.

The four request-stream diagnostics remain retained as observations; their cause is unproven. No full transport-clean claim is made. Scope is local Vitest/Workerd testing only, with no cloud, deployment, account activation, credential, or production-route proof.

Manifest serialization is compact UTF-8 JSON (`ensure_ascii=false`, sorted object keys, comma/colon separators), with files sorted by relative path. The manifest excludes itself and these committed evidence documents.
