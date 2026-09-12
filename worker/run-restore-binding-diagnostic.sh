#!/usr/bin/env bash
set -uo pipefail

worker_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$worker_dir/.." && pwd)"
provider_deps="/home/jes/commonplace-log/worker/node_modules"
output_dir="${RESTORE_DIAGNOSTIC_OUTPUT:-$root_dir/tmp/provider-restore-diagnostic-1}"
created_node_modules=false

if [[ -e "$output_dir" ]]; then
  echo "output already exists: $output_dir" >&2
  exit 2
fi
mkdir -p "$output_dir"

cleanup() {
  if [[ "$created_node_modules" == true && -L "$worker_dir/node_modules" &&
        "$(readlink -f "$worker_dir/node_modules")" == "$(readlink -f "$provider_deps")" ]]; then
    rm -f "$worker_dir/node_modules"
  fi
}
trap cleanup EXIT

if [[ ! -x "$provider_deps/.bin/vitest" || -e "$worker_dir/node_modules" ]]; then
  echo "pinned dependency or safe symlink precondition failed" >&2
  exit 2
fi
ln -s "$provider_deps" "$worker_dir/node_modules"
created_node_modules=true
if [[ "$(readlink -f "$worker_dir/node_modules")" != "$(readlink -f "$provider_deps")" ]]; then
  echo "node_modules identity check failed" >&2
  exit 2
fi

inputs=(
  "$worker_dir/test/realm/restore.binding.workers.test.ts"
  "$worker_dir/test/realm/schema.workers.test.ts"
  "$worker_dir/src/realm/store.ts"
  "$worker_dir/src/entry.ts"
  "$worker_dir/vitest.config.ts"
  "$worker_dir/vitest.workers.config.ts"
  "$worker_dir/wrangler.test.jsonc"
  "$worker_dir/package-lock.json"
  "$provider_deps/.package-lock.json"
  "$worker_dir/run-restore-binding-diagnostic.sh"
)
for input in "${inputs[@]}"; do
  [[ -f "$input" ]] || { echo "missing diagnostic input: $input" >&2; exit 2; }
done
sha256sum "${inputs[@]}" >"$output_dir/pre.sha256"
printf '%s\n' "$(git -C "$root_dir" rev-parse HEAD)" >"$output_dir/source-revision.txt"
printf '%s\n' "control=test/realm/schema.workers.test.ts" "target=test/realm/restore.binding.workers.test.ts" \
  "provider_deps=$provider_deps" >"$output_dir/diagnostic-inputs.txt"

set +e
cd "$worker_dir"
timeout --signal=TERM --kill-after=5s 180s env \
  NODE_PATH="$provider_deps" DEBUG="vite:resolve,vite:transform" \
  "$provider_deps/.bin/vitest" run --config "$worker_dir/vitest.config.ts" --project do \
  "test/realm/schema.workers.test.ts" "test/realm/restore.binding.workers.test.ts" \
  >"$output_dir/stdout.txt" 2>"$output_dir/stderr.txt"
native_rc=$?
set -e

sha256sum "${inputs[@]}" >"$output_dir/post.sha256"
verdict_rc="$native_rc"
if ! cmp -s "$output_dir/pre.sha256" "$output_dir/post.sha256"; then
  verdict_rc=125
  echo "diagnostic inputs changed during execution" >&2
fi
printf '%s\n' "$native_rc" >"$output_dir/native.rc"
printf '%s\n' "$verdict_rc" >"$output_dir/verdict.rc"
printf '{"native_rc":%s,"verdict_rc":%s,"output_dir":"%s"}\n' "$native_rc" "$verdict_rc" "$output_dir" >"$output_dir/result.json"
exit "$verdict_rc"
