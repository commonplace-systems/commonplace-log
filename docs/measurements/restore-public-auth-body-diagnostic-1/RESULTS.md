# Restore public auth body ownership diagnostic results

This one-arm observation is retained as an incomplete native result (`125`). Wrangler became ready and the exact fixture started, but the fixture failed after the wrong-secret response: its final authenticated inventory call returned `{:error, {:transport_error, :provider_failed}}`. The test therefore recorded one failure, with no exclusions or skips. No rerun was performed.

The safe instrumentation captured three complete phase pairs before the fixture stopped: `create/201` with `cancel=not_attempted`, `realm/200` with `cancel=not_attempted`, and `realm/401` with `cancel=error`. The fourth valid inventory pair was not observed because the fixture failed at the subsequent read. One request-stream diagnostic was present. The count is recorded as an observation; this output does not establish a cause or a fix.

Both owned groups were absent after cleanup. The recorded leader exits were `1` for Wrangler and `2` for the fixture; no KILL, timeout, or signal occurred. The 4,355 bound inputs and the 3,221-file worker runtime were equal before and after the run.

The runner records an internal 180-second outer constant, but that constant was not enforced by this execution. The native owner’s external wrapper supplied a 210-second run bound plus 30 seconds for cleanup. Readiness and fixture bounds were each 30 seconds; cleanup used TERM for five seconds and KILL for two seconds.

The complete raw output is bound by [output-manifest-1.json](output-manifest-1.json), SHA `2bb29b06a74c8c716f2dce817c6cac01cb4af6eae83d241ff9a052b972a41bdd`. It contains 61 regular files and one symlink, with canonical file-list digest `063fb3b04bcccc0347fa857b156c591c35714fae65de889c3b4e717f2d1ebc6c`. The provider source is `6213d4498354861c6e3a5ff8a047b93ce380304e`; the fixture is `c9011535742daea9ecb216185e54ed41a3d470af` with SHA `74ec70076df0a9e9058034234fd6951a110ddf65632b1d416c7fdd672327126f`.

This evidence covers only the local synthetic diagnostic arm. It does not claim clean transport, deployment, hosted authentication, cloud behavior, or account activation.
