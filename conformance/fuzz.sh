#!/usr/bin/env bash
# Cross-runtime differential fuzz for the canonical JSON serialization.
#
# The Elixir generator (commonplace_log/scripts/fuzz_differential.exs) emits
# N random I-JSON values, each as a canonical-by-construction .json input
# plus Elixir's re-parse-and-canonicalize .bin; the TypeScript side
# (worker/scripts/fuzz-check.ts) parses each .json and writes its own .bin.
# The verdict is rendered from cmp/diff over those FILES — never from an
# exit code alone and never from a test runner's summary:
#
#   Verdict A: per case, TS .bin must be byte-identical to Elixir .bin
#              (cross-runtime agreement).
#   Verdict B: per case, BOTH .bins must be byte-identical to the .json
#              itself — the inputs are canonical by construction, so any
#              inequality is a broken canonicalize∘parse fixpoint (B-ts for
#              TypeScript, B-ex for Elixir).
#
# Anti-vacuity: generated case count must equal N with a floor of 100, and
# the three file SETS (generated .json, Elixir .bin, TS .bin) are diffed
# against each other in both directions.
#
# The seed is ALWAYS printed (given or generated); reproduce any run with:
#
#   conformance/fuzz.sh <n> <seed>
#
# On failure every failing case is named with its byte diff — never
# truncated. On success a summary with counts and the domain SELECTOR.
# Any divergence found here must be frozen as a canonical-json/ vector
# BEFORE either implementation is changed (see conformance/README.md,
# "Divergence protocol").
#
# Usage: conformance/fuzz.sh [n] [seed]     (default n: 500)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

N="${1:-500}"
SEED="${2:-}"

if [ "$N" -lt 100 ]; then
  echo "FAIL: N=${N} is below the anti-vacuity floor of 100 cases"
  exit 1
fi

GEN="$(mktemp -d)"
TS_OUT="$(mktemp -d)"
LISTS="$(mktemp -d)"
trap 'rm -rf "$GEN" "$TS_OUT" "$LISTS"' EXIT

echo "== generate: Elixir (commonplace_log/scripts/fuzz_differential.exs) =="
if [ -n "$SEED" ]; then
  (cd "${REPO_ROOT}/commonplace_log" && mix run scripts/fuzz_differential.exs "$GEN" "$N" "$SEED")
else
  (cd "${REPO_ROOT}/commonplace_log" && mix run scripts/fuzz_differential.exs "$GEN" "$N")
fi
seed_used="$(cat "${GEN}/SEED")"
v2_count="$(cat "${GEN}/V2_COUNT")"
v2_with_operation_id_count="$(cat "${GEN}/V2_WITH_OPERATION_ID_COUNT")"
v2_without_operation_id_count=$((v2_count - v2_with_operation_id_count))

echo "== canonicalize: TypeScript (worker/scripts/fuzz-check.ts) =="
node "${REPO_ROOT}/worker/scripts/fuzz-check.ts" "$GEN" "$TS_OUT"

# ---- red-demo insertion point ----
# Sabotage for red demonstrations (corrupting a generated .bin or .json)
# goes HERE, in a scratchpad COPY of this script — never in this file.

fail=0

echo
echo "== anti-vacuity: case count and file sets =="
(cd "$GEN" && ls -1 fuzz-*.json 2>/dev/null | sed 's#\.json$##') | sort > "${LISTS}/gen-json" || true
(cd "$GEN" && ls -1 fuzz-*.bin 2>/dev/null | sed 's#\.bin$##') | sort > "${LISTS}/gen-bin" || true
(cd "$TS_OUT" && ls -1 fuzz-*.bin 2>/dev/null | sed 's#\.bin$##') | sort > "${LISTS}/ts-bin" || true

case_count="$(wc -l < "${LISTS}/gen-json")"
if [ "$case_count" -ne "$N" ]; then
  echo "FAIL: generator wrote ${case_count} .json cases but N=${N} were requested"
  fail=1
else
  echo "generated .json case count == N (${N})"
fi
if [ "$case_count" -lt 100 ]; then
  echo "FAIL: only ${case_count} cases present (< 100) — generation missing or wrong referent"
  fail=1
fi
if [ "$v2_with_operation_id_count" -lt 1 ] || [ "$v2_without_operation_id_count" -lt 1 ]; then
  echo "FAIL: v2 coverage missing (with operation_id=${v2_with_operation_id_count}, without=${v2_without_operation_id_count})"
  fail=1
else
  echo "v2 entry coverage: ${v2_count} total (${v2_with_operation_id_count} with operation_id, ${v2_without_operation_id_count} without)"
fi
if diff "${LISTS}/gen-json" "${LISTS}/gen-bin"; then
  echo "Elixir .bin file set == generated .json file set"
else
  echo "FAIL: Elixir .bin file set differs from the generated .json file set (see diff above)"
  fail=1
fi
if diff "${LISTS}/gen-json" "${LISTS}/ts-bin"; then
  echo "TS .bin file set == generated .json file set"
else
  echo "FAIL: TypeScript .bin file set differs from the generated .json file set (see diff above)"
  fail=1
fi

echo
echo "== verdicts: A (TS bin == EX bin), B-ts (TS bin == .json), B-ex (EX bin == .json) =="
a_pass=0
bts_pass=0
bex_pass=0
while IFS= read -r name; do
  json="${GEN}/${name}.json"
  ex_bin="${GEN}/${name}.bin"
  ts_bin="${TS_OUT}/${name}.bin"
  case_fail=0

  if [ -f "$ex_bin" ] && [ -f "$ts_bin" ] && cmp -s "$ts_bin" "$ex_bin"; then
    a_pass=$((a_pass + 1))
  else
    echo "${name}: verdict A FAIL — TS and Elixir canonical bytes differ"
    if [ -f "$ts_bin" ] && [ -f "$ex_bin" ]; then
      echo "-- TS vs EX (xxd diff):"
      diff <(xxd "$ts_bin") <(xxd "$ex_bin") || true
    else
      [ -f "$ts_bin" ] || echo "-- TS ${name}.bin is missing"
      [ -f "$ex_bin" ] || echo "-- EX ${name}.bin is missing"
    fi
    case_fail=1
  fi

  if [ -f "$ts_bin" ] && cmp -s "$ts_bin" "$json"; then
    bts_pass=$((bts_pass + 1))
  else
    echo "${name}: verdict B-ts FAIL — TS canonicalize(parse(.json)) != the .json bytes (fixpoint broken)"
    if [ -f "$ts_bin" ]; then
      echo "-- TS bin vs .json (xxd diff):"
      diff <(xxd "$ts_bin") <(xxd "$json") || true
    else
      echo "-- TS ${name}.bin is missing"
    fi
    case_fail=1
  fi

  if [ -f "$ex_bin" ] && cmp -s "$ex_bin" "$json"; then
    bex_pass=$((bex_pass + 1))
  else
    echo "${name}: verdict B-ex FAIL — Elixir canonicalize(decode(.json)) != the .json bytes (fixpoint broken)"
    if [ -f "$ex_bin" ]; then
      echo "-- EX bin vs .json (xxd diff):"
      diff <(xxd "$ex_bin") <(xxd "$json") || true
    else
      echo "-- EX ${name}.bin is missing"
    fi
    case_fail=1
  fi

  if [ "$case_fail" -ne 0 ]; then
    echo "-- ${name} input (.json):"
    cat "$json"
    echo
    fail=1
  fi
done < "${LISTS}/gen-json"

echo
echo "== summary =="
echo "SEED: ${seed_used} (reproduce: conformance/fuzz.sh ${N} ${seed_used})"
echo "cases generated:                        ${case_count} (requested N=${N}, floor 100)"
echo "v2 entries:                             ${v2_count} (${v2_with_operation_id_count} with operation_id, ${v2_without_operation_id_count} without)"
echo "verdict A pass (TS bin == EX bin):      ${a_pass}/${case_count}"
echo "verdict B-ts pass (TS bin == .json):    ${bts_pass}/${case_count}"
echo "verdict B-ex pass (EX bin == .json):    ${bex_pass}/${case_count}"
echo "SELECTOR: green means: TS==Elixir==input over ${case_count} random I-JSON values — including ${v2_count} valid v2 entry shapes (${v2_with_operation_id_count} with operation_id, ${v2_without_operation_id_count} without), null/true/false, integers within ±(2^53−1), finite doubles from random 64-bit patterns (subnormals/extremes included), well-formed-Unicode strings (controls, quotes, backslashes, astral), UTF-16-ordering-stress keys (BMP ≥ U+E000 mixed with astral), nesting to depth ~6; NOT covered: integers beyond ±(2^53−1), lone surrogates, duplicate keys (recorded-unpinned classes — see conformance/README.md), and everything invalid-entries covers."

if [ "$fail" -ne 0 ]; then
  echo "RESULT: RED — at least one check above failed"
  echo "Divergence protocol: minimize the failing input by hand and FREEZE it as a canonical-json/ vector (next number, SELECTOR + provenance updates) BEFORE changing either implementation. See conformance/README.md."
  exit 1
fi
echo "RESULT: GREEN"
