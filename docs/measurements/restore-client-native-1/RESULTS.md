# Restore client wire measurement

The original native-2 run compiled successfully and defined seven injected-transport tests. It reported six passing tests and one stale fixture failure: the oversized successful response now returns the closed `:invalid_response` protocol error, while the fixture expected `:response_body_too_large`. Its raw result remains preserved.

The native-3 continuation reused the eight retained isolated BEAMs and 847 pinned cached BEAM inputs. It executed the tagged oversized-response test through ExUnit’s `exclude: [:test]` plus `include: [restore_oversized_response: true]` filter. The retained summary was seven defined, zero failures, six excluded, and one executed; PRE/POST inputs were equal and native exit was 0.

Both runs use injected transport fixtures. They do not establish an actual HTTP client/provider or provider-auth integration. The continuation did not compile or replay the six green cases.

Complete provenance, commands, raw artifact paths, and SHA-256 hashes are in [RESULTS.json](./RESULTS.json). The original artifact roots are `/home/jes/commonplace-log-restore-client/tmp/restore-client-native-2` and `/home/jes/commonplace-log-restore-client/tmp/restore-client-native-3`.
