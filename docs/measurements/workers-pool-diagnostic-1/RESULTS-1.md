# Workers-pool diagnostic — run 1

This retained diagnostic ran two exact probes to test the proposed early-401/create-allocation explanation. Both arms completed natively with no stream diagnostics; the explanation was not reproduced. The probes do not localize or explain the ten diagnostics retained by the broader historical runs.

- `baseline-ingress`: deployment-token create probe; source `76f9028112feeba557e4d45060f1cbdead98e7f3`; native `0`; 1 selected assertion passed and 10 were excluded; zero diagnostics.
- `candidate-allocation`: deployment-bearer/read-capability allocation probe; source `4a22c1d65549577e42a12d390949d95e408eed2a`; native `0`; 1 selected assertion passed and 5 were excluded; zero diagnostics.

Input checks were equal in both arms: counts `3263` and `3265`, respectively. Runtime inventories remained unchanged at `3221` in both arms. Cleanup removed process groups `2080881` and `2080985`; neither arm sent TERM or KILL, timed out, or received a first signal.

This is diagnostic evidence only. It does not justify a source cleanup change and does not claim broad-suite coverage. The unchanged raw output is under `tmp/workers-pool-diagnostic-1/`; `OUTPUT-MANIFEST-1.json` hashes all retained regular files without following the two runtime symlinks.
