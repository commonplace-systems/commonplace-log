# Local restore HTTP native fixture

This fixture exercises the Elixir `Httpc` client against a fresh local Wrangler
process and a fixed test-only Durable Object wrapper. It runs one bounded
two-log workflow: malformed request reachability, local provisioning, partial
restore, ordinary-operation fencing, restart/resume, exact readback, and
idempotent replay.

The runner pins the client sidecar provenance and the wire fixture/product
commits in `source-pins.json`. Its child environment prepends the pinned OTP
runtime directory below so private `HOME` and XDG paths do not select asdf
shims:

```
/home/jes/.asdf/installs/erlang/27.3.4.8/bin
```

Run from this worktree with a fresh output directory:

```
python3 docs/measurements/restore-http-native-1/run_restore_http.py \
  /home/jes/commonplace-log-restore-http/tmp/restore-http-native-1
```
