#!/usr/bin/env bash
# Runs the wrangler real-socket integration arm BOTH ways and asserts the
# expected outcome of each:
#
#   green arm: RUN_WRANGLER_INTEGRATION=1 — boots `wrangler dev` on a real
#     127.0.0.1 socket (wrangler.integration.jsonc) and drives the adapter,
#     Engine, and DocumentProfile through it. Expected: PASSING suite, and
#     because `mix test` also exits 0 on a ZERO-test run (the env-var gate
#     silently not matching), a green exit is only believed when ExUnit's
#     summary shows >= 1 test with 0 failures and the test's own
#     WRANGLER_READY / POSITIVE_CONTROL markers were printed.
#
#   red arm: WRANGLER_INTEGRATION_RED_ARM=wrong_port additionally points the
#     adapter at a port wrangler is NOT listening on. Expected: FAILING suite
#     — this is the arm that proves the green arm above can go red at all.
#     The red exit is only believed when SABOTAGE_APPLIED was printed (the
#     sabotage actually happened) and the summary shows >= 1 test with >= 1
#     failure (a boot crash marks tests invalid, not failed, and must not
#     count as detection).
#
# Expected outcomes were OBSERVED locally on 2026-09-14 before this gate was
# written: green arm exit 0 "2 tests, 0 failures"; red arm exit 2
# "2 tests, 2 failures" with SABOTAGE_APPLIED printed.
#
# Needs: node on PATH, `npm ci` already run in the worker directory, and no
# Cloudflare credentials at all (local socket only).
#
# Usage: COMMONPLACE_LOG_WORKER_DIR=../worker bash scripts/check_wrangler_arms.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 70

: "${COMMONPLACE_LOG_WORKER_DIR:?set COMMONPLACE_LOG_WORKER_DIR (e.g. ../worker)}"
arm_file=test/wrangler_real_socket_integration_test.exs
if [ ! -f "$arm_file" ]; then
  echo "WRANGLER ARMS: REFUSE — ${arm_file} does not exist; nothing to run."
  exit 70
fi
if [ ! -f "${COMMONPLACE_LOG_WORKER_DIR}/node_modules/wrangler/bin/wrangler.js" ]; then
  echo "WRANGLER ARMS: REFUSE — wrangler is not installed under"
  echo "${COMMONPLACE_LOG_WORKER_DIR}/node_modules; run \`npm ci\` there first."
  exit 70
fi

fail=0

echo "== wrangler green arm: RUN_WRANGLER_INTEGRATION=1 (expected: PASS) =="
out="$(RUN_WRANGLER_INTEGRATION=1 mix test "$arm_file" 2>&1)"
rc=$?
printf '%s\n' "$out" | grep -E 'WRANGLER_READY|POSITIVE_CONTROL|tests?,' || true
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out"
  echo "FAIL(green): suite exited ${rc}; the real-socket integration is broken."
  fail=1
elif ! printf '%s\n' "$out" | grep -qE '[1-9][0-9]* (test|tests), 0 failures'; then
  printf '%s\n' "$out"
  echo "FAIL(green): exit 0 but no summary showing >= 1 test with 0 failures —"
  echo "a zero-test run (env-var gate not matching) prints exit 0 too, and that"
  echo "would certify nothing."
  fail=1
elif ! printf '%s\n' "$out" | grep -q 'WRANGLER_READY'; then
  printf '%s\n' "$out"
  echo "FAIL(green): tests passed but WRANGLER_READY was never printed — the run"
  echo "did not demonstrably go through a booted wrangler process."
  fail=1
else
  echo "ok: green arm passed against a real wrangler socket."
fi

echo "== wrangler red arm: WRANGLER_INTEGRATION_RED_ARM=wrong_port (expected: RED) =="
out="$(RUN_WRANGLER_INTEGRATION=1 WRANGLER_INTEGRATION_RED_ARM=wrong_port mix test "$arm_file" 2>&1)"
rc=$?
printf '%s\n' "$out" | grep -E 'WRANGLER_READY|SABOTAGE_APPLIED|tests?,' || true
if [ "$rc" -eq 0 ]; then
  printf '%s\n' "$out"
  echo "FAIL(red): the sabotaged run came back GREEN — the green arm above is not"
  echo "known to be able to fail, so its pass certifies nothing."
  fail=1
elif ! printf '%s\n' "$out" | grep -q 'SABOTAGE_APPLIED'; then
  printf '%s\n' "$out"
  echo "FAIL(red): red exit (${rc}) but SABOTAGE_APPLIED was never printed — the"
  echo "failure is something other than the intended sabotage."
  fail=1
elif ! printf '%s\n' "$out" | grep -qE '[1-9][0-9]* (test|tests), [1-9][0-9]* (failure|failures)'; then
  printf '%s\n' "$out"
  echo "FAIL(red): red exit (${rc}) but no summary with >= 1 test and >= 1 failure —"
  echo "a crash or invalid-marked run, not the assertions detecting the sabotage."
  fail=1
else
  echo "ok: red arm went red for the right reason (sabotage applied and detected)."
fi

if [ "$fail" -ne 0 ]; then
  echo "WRANGLER ARMS: FAIL — see above."
  exit 1
fi
echo "WRANGLER ARMS: OK — green arm passed and its red arm demonstrably fails."
