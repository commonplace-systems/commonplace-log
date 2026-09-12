#!/usr/bin/env bash
set -uo pipefail

worker_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runner_dir="$(cd "$worker_dir/.." && pwd)"
provider_deps="/home/jes/commonplace-log/worker/node_modules"
output_dir="${RESTORE_CAPACITY_CONTINUE_OUTPUT:-$runner_dir/tmp/provider-restore-capacity-3}"
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

if [[ ! -x "$provider_deps/.bin/vitest" ]]; then
  echo "missing pinned provider node_modules: $provider_deps" >&2
  exit 2
fi
if [[ -e "$worker_dir/node_modules" ]]; then
  echo "worker node_modules path is occupied; refusing to replace it" >&2
  exit 2
fi
ln -s "$provider_deps" "$worker_dir/node_modules"
created_node_modules=true
if [[ "$(readlink -f "$worker_dir/node_modules")" != "$(readlink -f "$provider_deps")" ]]; then
  echo "node_modules identity check failed" >&2
  exit 2
fi

inputs=(
  "$worker_dir/src/realm/schema.ts"
  "$worker_dir/src/realm/store.ts"
  "$worker_dir/src/entry.ts"
  "$worker_dir/src/jcs.ts"
  "$worker_dir/test/realm/helpers.ts"
  "$worker_dir/test/realm/restore-capacity.workers.test.ts"
  "$worker_dir/package-lock.json"
  "$provider_deps/.package-lock.json"
  "$worker_dir/vitest.config.ts"
  "$worker_dir/vitest.workers.config.ts"
  "$worker_dir/wrangler.test.jsonc"
  "$worker_dir/run-restore-capacity-continue.sh"
)
for input in "${inputs[@]}"; do
  [[ -f "$input" ]] || { echo "missing runner input: $input" >&2; exit 2; }
done

sha256sum "${inputs[@]}" >"$output_dir/pre.sha256"
printf '%s\n' "$(git -C "$runner_dir" rev-parse HEAD)" >"$output_dir/source-revision.txt"
printf '%s\n' "provider_deps=$provider_deps" >"$output_dir/runner-inputs.txt"

set +e
cd "$worker_dir"
timeout --signal=TERM --kill-after=5s 180s \
  env NODE_PATH="$provider_deps" "$provider_deps/.bin/vitest" \
  run --config "$worker_dir/vitest.config.ts" --project do \
  "test/realm/restore-capacity.workers.test.ts" \
  >"$output_dir/stdout.txt" 2>"$output_dir/stderr.txt"
native_rc=$?
set -e
verdict_rc="$native_rc"

sha256sum "${inputs[@]}" >"$output_dir/post.sha256"
if ! cmp -s "$output_dir/pre.sha256" "$output_dir/post.sha256"; then
  echo "runner inputs changed during execution" >&2
  verdict_rc=125
fi
printf '%s\n' "$native_rc" >"$output_dir/native.rc"
printf '%s\n' "$verdict_rc" >"$output_dir/verdict.rc"
printf '{"native_rc":%s,"verdict_rc":%s,"output_dir":"%s"}\n' "$native_rc" "$verdict_rc" "$output_dir" >"$output_dir/result.json"
exit "$verdict_rc"
