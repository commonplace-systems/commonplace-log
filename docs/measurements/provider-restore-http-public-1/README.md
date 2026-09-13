# Public provider restore HTTP runner

This packet selects the committed `restore-public.workers.test.ts` fixture and
the one updated authorization assertion in `restore-wire.workers.test.ts`.
The three fixture cases execute the public Worker ingress through `SELF`, which
authenticates and forwards to the test-only `REALM_CONTAINER` fallback's
`RealmContainer.fetch`. The fourth case is the direct authenticated
`DurableObjectStub.fetch` contract assertion from `restore-wire`; it remains a
public authorization check but is not a gateway `SELF` test. No selected test
calls `storageFetch` directly.

The source pin is the public-provider product at `fe11cac5b14bec92b0d7ef71b5a1599b08a3dab2` or a clean descendant with the
same `worker/src`, package, and lockfile bytes. The runner records the actual
archived HEAD. The reviewed fixture commit is
`e760fb1b18f91fccbdfdd16156cd08636f5715ff`; the runner checks both selected
fixture file hashes against that commit. The fixture provides three cases; the updated
authorization contract contributes one, for four passed tests total.

Run only after the fixture commit is present and the worktree is clean:

```text
python3 docs/measurements/provider-restore-http-public-1/run_provider_restore_http_public.py /absolute/fresh/provider-restore-http-public-1
```

The runner uses the pinned local `/home/jes/commonplace-log/worker/node_modules`
tree, private HOME/XDG/TMP/cache directories, and the local Cloudflare Vitest
worker pool. It records the selected argv, source/runtime SHA-256 maps before
and after, separate stdout/stderr and JSON result files, native return codes,
and process-group cleanup. The child bound is 180 seconds; cleanup sends TERM
with a five-second grace and KILL with a two-second grace. No dependency
installation, cloud endpoint, deployment, account activation, or credential
materialization is part of this packet.
