# Consolidated allocation assertion coverage

All seven allocation assertions have a passing authoritative receipt across the preserved initial run and focused continuations. The initial run and five-case continuation remain recorded with their original incomplete outcomes; the spoof-only run supplies the final reserved-path receipt without broad replay.

| Assertion | Authoritative receipt | Result |
|---|---|---|
| Idempotent retry | `RESULTS.json` | pass |
| Conflicting operation/secret refusal | `RESULTS.json` | pass |
| Legacy-created realm refusal | `RESULTS-2.json` | pass |
| Bearer authorization refusal | `RESULTS-2.json` | pass |
| Internal path/spoof-marker refusal | `RESULTS-3.json` | pass |
| Plaintext secret exclusion | `RESULTS-2.json` | pass |
| Malformed secret rejection | `RESULTS-2.json` | pass |

No exact cause is assigned to the original isolated-storage failure or the continuation wrapper diagnostics. The provider source was not deployed or hosted-tested. Machine-readable coverage is in [`COVERAGE-7.json`](COVERAGE-7.json).
