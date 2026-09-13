# Restore public auth body ownership diagnostic

This packet runs one exact fixture case against the diagnostic provider arm at commit `6213d4498354861c6e3a5ff8a047b93ce380304e`:

`test rejects a body-bearing wrong secret before returning the unchanged empty inventory`

The fixture is pinned to app commit `c9011535742daea9ecb216185e54ed41a3d470af`, file SHA `74ec70076df0a9e9058034234fd6951a110ddf65632b1d416c7fdd672327126f`. The runner materializes the real `worker/src/index.ts` and the provider configuration from the diagnostic commit, adds only the synthetic `GATEWAY_TOKEN=test-gateway-token`, and starts one local Wrangler process. It uses the accepted retained `Httpc` client/eBins and cached BEAM receipt from the earlier public operation output; it does not compile or start `:commonplace_next`.

The diagnostic source records only safe body state (`used` and `locked`), category, status, and cancellation outcome before forwarding and after the Durable Object response. The runner requires the expected four phase pairs in order: `create/201`, `realm/200`, `realm/401`, `realm/200`. It records the exact request-stream diagnostic count as an observation and does not require that count to be zero. The fixture itself must pass exactly one test with no failures, exclusions, or skips.

The native owner runs:

```text
python3 -B docs/measurements/restore-public-auth-body-diagnostic-1/run_restore_public_auth_diagnostic.py /absolute/path/to/tmp/restore-public-auth-body-diagnostic-1
```

Readiness and the fixture each have a 30 second bound; the complete one-arm run has a 180 second outer bound, with TERM for five seconds and KILL for two seconds during owned cleanup. The runner preserves the first signal, restores the child signal mask after spawn, keeps the finalization latch active while writing traces, hashes, and verdict, and refreshes all input/runtime membership after execution.

This packet is an observation of a local synthetic provider ingress. It does not claim a transport fix, deployment, hosted authentication, account activation, cloud behavior, or a cause for any request-stream error. It has not been executed in this worktree.
