# Cloudflare sidecar log inventory client packet

This packet adds the internal `CloudflareSidecar.list_log_inventory/2` client call for the
provider's configured `/list-logs` storage endpoint. The request is exactly `POST /list-logs` with
`{"max_logs": 1..64}`. The parser accepts only the provider's closed `{ok, result}` shape,
requires a lowercase 64-character generation digest, sorted unique log IDs, exact log and writer
metadata fields, nullable document writer IDs, sorted unique writer IDs, UTF-8 strings bounded to
256 bytes, and at most 4,096 writer rows. The raw JSON response is capped at 256 KiB after the
transport returns it.

The dedicated response path maps the provider's `malformed`, `constraint`, `obsolete_epoch`,
`oversize`, and `storage_full` errors, treats 5xx responses as closed transport failures, and
catches transport errors, raises, throws, and exits without returning URLs, headers, bodies, or
native exception terms. Existing ordinary adapter methods are unchanged.

The focused test file contains exactly eight cases covering empty and mixed metadata success,
input/output bounds, unknown fields, duplicate and unsorted rows, malformed safe integers,
transport raise/throw/exit closure, and status/error mapping. Root owns native execution; the
fresh-output runner compiles the selected client source against the pinned 847 cached BEAM files,
records PRE/POST hashes, strips secret-like environment variables, and owns compile/test process
groups with bounded cleanup.

From the repository root, root may run:

```text
python3 docs/measurements/log-inventory-client-1/run_log_inventory_client.py <fresh-output-dir>
```

This is a client parser and wire-shape proof using injected transport tests. It does not claim an
actual provider HTTP round trip or account/auth admission.
