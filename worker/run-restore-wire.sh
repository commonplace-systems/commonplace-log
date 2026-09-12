#!/usr/bin/env bash
set -uo pipefail

worker_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runner_dir="$(cd "$worker_dir/.." && pwd)"
provider_deps="/home/jes/commonplace-log/worker/node_modules"
output_dir="${RESTORE_WIRE_OUTPUT:-$runner_dir/tmp/provider-restore-wire-1}"
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
  "$worker_dir/src/index.ts"
  "$worker_dir/src/commonplace-log-do.ts"
  "$worker_dir/src/entry.ts"
  "$worker_dir/src/jcs.ts"
  "$worker_dir/src/do/http.ts"
  "$worker_dir/src/do/merge-plan.ts"
  "$worker_dir/src/do/schema.ts"
  "$worker_dir/src/do/store.ts"
  "$worker_dir/src/do/uuid.ts"
  "$worker_dir/src/realm/container.ts"
  "$worker_dir/src/realm/http.ts"
  "$worker_dir/src/realm/node.ts"
  "$worker_dir/src/realm/outbound.ts"
  "$worker_dir/src/realm/capacity.ts"
  "$worker_dir/src/realm/realm_auth.ts"
  "$worker_dir/src/realm/schema.ts"
  "$worker_dir/src/realm/store.ts"
  "$worker_dir/src/realm/wire.ts"
  "$worker_dir/test/realm/http.workers.test.ts"
  "$worker_dir/test/realm/ingress.workers.test.ts"
  "$worker_dir/test/realm/outbound.test.ts"
  "$worker_dir/test/realm/restore-wire.workers.test.ts"
  "$worker_dir/package-lock.json"
  "$provider_deps/.package-lock.json"
  "$worker_dir/vitest.config.ts"
  "$worker_dir/vitest.workers.config.ts"
  "$worker_dir/wrangler.test.jsonc"
  "$worker_dir/run-restore-wire.sh"
)
for input in "${inputs[@]}"; do
  [[ -f "$input" ]] || { echo "missing runner input: $input" >&2; exit 2; }
done

sha256sum "${inputs[@]}" >"$output_dir/pre.sha256"
printf '%s\n' "$(git -C "$runner_dir" rev-parse HEAD)" >"$output_dir/source-revision.txt"
printf '%s\n' "provider_deps=$provider_deps" >"$output_dir/runner-inputs.txt"
printf '%s\n' "timeout --signal=TERM --kill-after=5s 270s: vitest do (restore-wire,http,ingress), then vitest unit (outbound)" >"$output_dir/command.txt"

set +e
cd "$worker_dir"
timeout --signal=TERM --kill-after=5s 270s bash -c '
  set +e
  "$1/.bin/vitest" run --config "$2/vitest.config.ts" --project do \
    "test/realm/restore-wire.workers.test.ts" \
    "test/realm/http.workers.test.ts" \
    "test/realm/ingress.workers.test.ts" \
    >"$3/stdout.txt" 2>"$3/stderr.txt"
  do_rc=$?
  "$1/.bin/vitest" run --config "$2/vitest.config.ts" --project unit \
    "test/realm/outbound.test.ts" \
    >>"$3/stdout.txt" 2>>"$3/stderr.txt"
  unit_rc=$?
  printf "%s\n" "$do_rc" >"$3/do.rc"
  printf "%s\n" "$unit_rc" >"$3/unit.rc"
  if [ "$do_rc" -ne 0 ]; then exit "$do_rc"; fi
  exit "$unit_rc"
' bash "$provider_deps" "$worker_dir" "$output_dir"
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
