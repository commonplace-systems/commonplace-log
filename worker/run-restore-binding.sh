#!/usr/bin/env bash
set -uo pipefail

runner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
worker_dir="$(cd "$runner_dir/worker" && pwd)"
provider_deps="/home/jes/commonplace-log/worker/node_modules"
output_dir="${RESTORE_BINDING_OUTPUT:-$runner_dir/tmp/restore-binding-native-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$output_dir"

if [[ ! -x "$provider_deps/.bin/vitest" ]]; then
  echo "missing pinned provider node_modules: $provider_deps" >&2
  exit 2
fi

sha256sum "$runner_dir/worker/src/realm/schema.ts" "$runner_dir/worker/src/realm/store.ts" \
  "$runner_dir/worker/test/realm/restore.binding.workers.test.ts" "$worker_dir/package-lock.json" \
  "$provider_deps/.package-lock.json" 2>/dev/null >"$output_dir/pre.sha256"
printf '%s\n' "$(git -C "$runner_dir" rev-parse HEAD)" >"$output_dir/source-revision.txt"
printf '%s\n' "provider_deps=$provider_deps" >"$output_dir/runner-inputs.txt"

set +e
timeout --signal=TERM --kill-after=5s 180s \
  env NODE_PATH="$provider_deps" "$provider_deps/.bin/vitest" run \
  --config "$runner_dir/worker/vitest.workers.config.ts" \
  "$runner_dir/worker/test/realm/restore.binding.workers.test.ts" \
  >"$output_dir/stdout.txt" 2>"$output_dir/stderr.txt"
native_rc=$?
set -e

sha256sum "$runner_dir/worker/src/realm/schema.ts" "$runner_dir/worker/src/realm/store.ts" \
  "$runner_dir/worker/test/realm/restore.binding.workers.test.ts" "$worker_dir/package-lock.json" \
  "$provider_deps/.package-lock.json" 2>/dev/null >"$output_dir/post.sha256"
printf '%s\n' "$native_rc" >"$output_dir/native.rc"
printf '{"native_rc":%s,"output_dir":"%s"}\n' "$native_rc" "$output_dir" >"$output_dir/result.json"
exit "$native_rc"
