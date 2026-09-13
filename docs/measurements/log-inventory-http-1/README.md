# Real HTTP provider log inventory draft

This draft runs one real loopback workflow through Elixir `:httpc`, local
Wrangler, the fixed test-only `RealmContainer` Durable Object, and SQLite. The
wrapper exposes only the fixed internal storage paths needed by the workflow;
it does not make a public authentication or cloud RPC claim. Realm creation
consumes the bounded literal `{}` body before forwarding a bodyless request,
removing `content-length` and `transfer-encoding` from the forwarded headers.

The workflow provisions a fresh realm, observes an empty inventory, restores a
sorted two-log bundle in two batches, verifies the pending `obsolete_epoch`
fence, checks sorted metadata and writer tips, verifies exact replay generation
stability, creates a third ordinary log, commits one canonical entry, and
reads that exact canonical byte sequence back. It then checks generation
changes after creation and commit. It expects one ExUnit test with zero
failures, exclusions, or skips.

The runner requires an explicit accepted full client SHA in
`LOG_INVENTORY_CLIENT_COMMIT`; it refuses to execute without that pin or when
the client worktree HEAD differs. It archives the current provider worktree,
verifies its worker product remains based on provider product
`804c4d43d7d56ed16942ea365733bd30e0674eaa`, and binds the client/provider
sources, cached BEAMs, worker runtime files, exact commands, raw streams, and
owned process groups before and after execution.

After the client pin is accepted, run from this worktree:

```text
LOG_INVENTORY_CLIENT_COMMIT=<accepted-full-client-sha> \
python3 docs/measurements/log-inventory-http-1/run_log_inventory_http.py /absolute/fresh/output
```

No dependency installation, cloud endpoint, deployment, account activation,
or public route is part of this draft. Native execution is intentionally held
until the accepted client SHA is supplied.
