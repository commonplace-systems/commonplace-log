# Empty restore client native evidence

The retained native run completed successfully in `tmp/restore-client-empty-entries-1`.
It used source commit `17ae2d1b8f0ace103208bea80e0936852626d084`, accepted base `32c1889023be5130428cfa128556bef39b367dda`, the pinned 847 cached BEAM inputs, and the runner command recorded in `command.json`.

The complete test file defined 9 tests; the tag-selected run executed the 2 new empty-entry controls, excluded 7 existing tests, and reported 0 failures and 0 skipped tests. The wrapper recorded native exit 0, verdict exit 0, 879 PRE/POST inputs with equal manifests (32 source files plus 847 cached BEAMs), PID/PGID `1328694` absent after cleanup, no timeout, signal, forced kill, or cleanup hold. The native stdout/stderr and all process records remain at the retained raw paths listed in `RESULTS.json`.

The emitted isolated compiler output contains 8 BEAM files. `RESULTS.json` records each relative path, byte count, and SHA-256 digest; the algorithm is SHA-256 over the emitted file bytes. The raw input manifests retain the complete 847 dependency hash map and source hash map.

This evidence covers client request encoding and closed null-writer preflight through injected transport. It does not claim an actual provider HTTP round trip, account admission, credentials, or restore mutation.

All direct raw artifact hashes and the emitted BEAM manifest are bound in [`RESULTS.json`](RESULTS.json).
