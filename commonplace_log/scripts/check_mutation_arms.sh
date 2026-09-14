#!/usr/bin/env bash
# Runs the four PERSISTENCE_CONTRACT_MUTATION anti-vacuity arms and asserts
# the EXPECTED outcome of each — which is a FAILING suite.
#
# Each mutation compiles a deliberately broken persistence adapter (or lane)
# into the contract suite; a contract worth anything must go RED on it. So a
# plain "exit 0 == pass" gate here would be green for exactly the wrong
# reason: it would certify that the contract CANNOT see the breakage. This
# script inverts the exit code, and then refuses two ways a red-or-green
# verdict could still lie:
#
#   1. VACUITY: `mix test` exits 0 when it runs ZERO tests, which is exactly
#      what happens if the env-var gate in the test file stops matching the
#      value (the `_unset -> :ok` branch). So a green run must never be
#      trusted here at all, and a red run must show >= 1 test AND >= 1
#      failure in ExUnit's own summary line — a compile crash prints no such
#      line and is reported as a crash, not as detection.
#   2. WRONG REFERENT: the failure must be attributed to the Broken* module
#      this mutation compiles, not to some unrelated red test that happened
#      to share the run.
#
# Expected outcomes were OBSERVED locally on 2026-09-14 before this gate was
# written (mix test test/persistence_contract_anti_vacuity_test.exs):
#   epoch              exit 2, 14 tests, 1 failure  (BrokenEpochTest)
#   revision           exit 2, 14 tests, 2 failures (BrokenRevisionTest)
#   creating_read      exit 2, 14 tests, 1 failure  (BrokenCreatingReadTest)
#   sidecar_lane_epoch exit 2,  1 test,  1 failure  (BrokenSidecarLaneEpochTest)
# Only the shape (>= 1 test, >= 1 failure, right module) is pinned here; the
# exact counts may grow with the contract.
#
# Usage: bash scripts/check_mutation_arms.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 70

arm_file=test/persistence_contract_anti_vacuity_test.exs
if [ ! -f "$arm_file" ]; then
  echo "MUTATION ARMS: REFUSE — ${arm_file} does not exist; there is nothing to run,"
  echo "and a loop over zero arms would print OK while proving nothing."
  exit 70
fi

expected_module() {
  case "$1" in
    epoch) echo "Commonplace.Log.PersistenceContract.BrokenEpochTest" ;;
    revision) echo "Commonplace.Log.PersistenceContract.BrokenRevisionTest" ;;
    creating_read) echo "Commonplace.Log.PersistenceContract.BrokenCreatingReadTest" ;;
    sidecar_lane_epoch) echo "Commonplace.Log.PersistenceContract.BrokenSidecarLaneEpochTest" ;;
    *) return 1 ;;
  esac
}

fail=0
for value in epoch revision creating_read sidecar_lane_epoch; do
  module="$(expected_module "$value")" || exit 70
  echo "== mutation arm: PERSISTENCE_CONTRACT_MUTATION=${value} (expected: RED, in ${module}) =="

  out="$(PERSISTENCE_CONTRACT_MUTATION="$value" mix test "$arm_file" 2>&1)"
  rc=$?

  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$out"
    echo "FAIL(${value}): the mutated suite ran GREEN (exit 0) — either the contract"
    echo "cannot see this breakage, or the arm compiled zero tests (vacuous run)."
    fail=1
    continue
  fi

  summary="$(printf '%s\n' "$out" | grep -E '[1-9][0-9]* (test|tests), [1-9][0-9]* (failure|failures)' | tail -1)"
  if [ -z "$summary" ]; then
    printf '%s\n' "$out"
    echo "FAIL(${value}): red exit (${rc}) but no ExUnit summary with >= 1 test and"
    echo ">= 1 failure — that is a crash or a zero-test run, not the contract detecting"
    echo "the mutation."
    fail=1
    continue
  fi

  if ! printf '%s\n' "$out" | grep -q "(${module})"; then
    printf '%s\n' "$out"
    echo "FAIL(${value}): the suite went red but no failure is attributed to ${module} —"
    echo "wrong referent; this red does not certify that THIS mutation was detected."
    fail=1
    continue
  fi

  echo "ok: exit ${rc}, ${summary}, failure attributed to ${module}"
done

if [ "$fail" -ne 0 ]; then
  echo "MUTATION ARMS: FAIL — at least one arm above did not produce its expected outcome."
  exit 1
fi
echo "MUTATION ARMS: OK — all 4 mutations were detected by the persistence contract."
