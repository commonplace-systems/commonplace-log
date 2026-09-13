# Log inventory client native evidence

This packet records two raw native attempts for the eight-case `CloudflareSidecar.list_log_inventory/2` client suite. The first attempt remains a compile failure; the second is the accepted replacement. No test or source result from the first attempt is relabeled as passing.

## Accepted result

Run `tmp/log-inventory-client-2` used source commit `32c1889023be5130428cfa128556bef39b367dda` and source-file SHA-256 `7176c8e583d05296c3b831da2132248896934facacfa497a86e207fca78f4f6a`. It returned native rc 0 with exactly 8 tests, 0 failures, 0 skipped, and 0 excluded. The wrapper also returned 0. PRE and POST input manifests were equal for 32 selected source files plus 847 cached BEAM files (879 total). The recorded PID and PGID were independently absent after cleanup; no timeout, received signal, or forced kill was recorded.

The suite covers empty and mixed inventory metadata, request and response bounds, unknown/duplicate/unsorted fields, malformed safe integers and bounded strings, transport raise/throw/exit closure, and closed status/error mapping. It uses injected transport tests and therefore does not establish a provider HTTP round trip or account/auth admission.

## Retained original attempt

Run `tmp/log-inventory-client-1` used source commit `83ed58119ddf1944f97d5b2ee4b8533a28852b6f` and failed during compilation before tests ran (native rc 1; wrapper verdict rc 125). Its raw stderr is retained. The concrete failure was the invalid `%__MODULE__{}` pattern in the default-argument function head, followed by unsupported `Exception.format_diagnostics/1` handling on Elixir 1.18.4. The correction is present in the accepted source commit; the original artifact remains unchanged.

## Raw binding

The accompanying `RESULTS.json` contains a recursive file map with byte count and SHA-256 for every retained raw file in both output directories, including command/source pins, PRE/POST manifests, verdict and native-exit records, streams, root-completion records, and all eight emitted isolated BEAM files from run 2. Each manifest uses sorted UTF-8 relative path, NUL, lowercase SHA-256 hex, and LF serialization. The JSON also records the complete source and cached-BEAM input maps from each raw run.

The native runner compiled and tested in one owned child with a 180-second bound and 5-second cleanup grace. The packet is evidence for this focused client stage only; it does not claim broader restore, cloud, or account behavior.
