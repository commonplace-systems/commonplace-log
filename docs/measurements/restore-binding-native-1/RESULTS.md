# Native restore binding evidence

The product source was pinned to `bc1ec30cdc813cc7cb6c4b2dbf78b3eb4ad40f7b`. The original native run (session `82500`) executed 28 tests and recorded 27 passing tests plus one assertion-shape failure. The continuation (session `86070`) selected that exact test by name, executed one test with 22 excluded, and passed with native exit `0`.

The combined evidence is 27 original green tests plus the corrected test, with zero failures and zero timeouts. The continuation recorded equal pre/post input hashes and equal pre/post hashes for every reused BEAM tree. The original raw outputs remain under `tmp/restore-binding-native-1`; continuation outputs remain under `tmp/restore-binding-native-2`.

Exact artifact hashes are recorded in [RESULTS.json](RESULTS.json). The continuation command was:

```text
RESTORE_BINDING_NATIVE1_OUT=/home/jes/commonplace-log-restore-binding/tmp/restore-binding-native-1 RESTORE_BINDING_BEAM_ROOT=/home/jes/codex-save-state-1/tmp/origin-receipt-1/_build/test/lib python3 docs/measurements/local-restore-binding-1/run_continue.py /home/jes/commonplace-log-restore-binding/tmp/restore-binding-native-2
```
