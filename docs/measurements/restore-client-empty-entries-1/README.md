# Empty restore archive client packet

This packet exercises the configured `CloudflareSidecar.restore_bundle_batch/3`
client support for a non-null writer whose restore archive has `entries: []`.
The client preserves the existing bounded log, writer, archive, entry, and
aggregate byte checks, emits an empty JSON `entries` array, and rejects a null
writer before transport. The two new tests are tagged
`restore_empty_entries`; the runner loads the complete nine-test source file,
then requires exactly two tests, seven excluded tests, and zero skipped tests.

The native runner is based on accepted client commit `32c1889`, compiles the
six client source files against the pinned 847 cached BEAM files, and runs
compile plus selected tests in one owned child with a 180-second bound and
5-second cleanup grace. It records source and cached-BEAM PRE/POST hashes,
strips secret-like environment variables, records PID/PGID and signal state,
and gates the verdict on input equality, exact test counts, and owned-process
cleanup.

From the repository root, run with a fresh output directory:

```text
python3 docs/measurements/restore-client-empty-entries-1/run_restore_client_empty_entries.py <fresh-output-dir>
```

Root owns native execution. No native run or dependency installation was
performed while authoring this packet.
