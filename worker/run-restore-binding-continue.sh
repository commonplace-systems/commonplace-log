#!/usr/bin/env bash
set -euo pipefail

runner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RESTORE_BINDING_TEST_FILTER="rejects a corrupted pending prefix and a missing completed row"
export RESTORE_BINDING_OUTPUT="${RESTORE_BINDING_OUTPUT:-$runner_dir/tmp/provider-restore-native-continuation-1}"
exec "$runner_dir/worker/run-restore-binding.sh"
