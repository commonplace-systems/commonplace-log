# Empty-owned restore continuation

This continuation reruns all six cases after the original run's isolated
storage teardown failure. It preserves the original output at
`tmp/provider-restore-empty-owned-1` and writes a recursive SHA-256 audit of
that tree, including its supplemental `root-completion.json`, into the fresh
continuation output before archiving or launching the worker.

The continuation does not select or replay a subset: all six frozen cases
run in the `do` Vitest project. It archives the clean current HEAD, uses the
pinned worker dependency tree, private cache/HOME/XDG/TMP roots, and retains
runtime membership PRE/POST, stdout/stderr, test JSON, native rc, process
groups, and verdict. The child bound is 120 seconds with TERM five-second and
KILL two-second grace.

Run only with a fresh output directory after the fixture/product commit is
clean:

```sh
python3 docs/measurements/provider-restore-empty-owned-1/run_provider_restore_empty_owned_continue.py \
  /home/jes/commonplace-log-restore-empty-owned/tmp/provider-restore-empty-owned-2
```

Root owns native execution. The original run remains a failed historical
record; its raw files are not rewritten.
