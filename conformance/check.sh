#!/usr/bin/env bash
# Cross-runtime byte-diff harness for the canonical-json conformance corpus.
#
# Emits canonical bytes from BOTH runtimes to files, then renders its verdict
# from diff/cmp over those FILES — never from an exit code alone and never
# from a test runner's summary.
#
#   Verdict A: the TypeScript and Elixir emitted trees must be byte-identical
#              on EVERY case, including 9xx (both produce the CORRECT bytes
#              for 999-deliberate-mismatch; they must agree with each other
#              even where they disagree with the stored expectation).
#   Verdict B: per case vs decoded expected.hex — every non-9xx case must
#              MATCH; every 9xx case must MISMATCH (a 9xx that matches means
#              the harness or corpus is broken).
#
# Anti-vacuity: the emitted file SETS are diffed against the corpus case list
# in both directions, and the run fails if fewer than 19 cases were checked.
#
# Usage: conformance/check.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CORPUS_DIR="${SCRIPT_DIR}/canonical-json"

TS_OUT="$(mktemp -d)"
EX_OUT="$(mktemp -d)"
EXP_OUT="$(mktemp -d)"
LISTS="$(mktemp -d)"
trap 'rm -rf "$TS_OUT" "$EX_OUT" "$EXP_OUT" "$LISTS"' EXIT

echo "== emit: TypeScript (worker/scripts/emit-vectors.ts) =="
node "${REPO_ROOT}/worker/scripts/emit-vectors.ts" "$TS_OUT"

echo "== emit: Elixir (commonplace_log/scripts/emit_vectors.exs) =="
(cd "${REPO_ROOT}/commonplace_log" && mix run scripts/emit_vectors.exs "$EX_OUT")

echo "== decode: expected.hex -> bytes =="
for dir in "${CORPUS_DIR}"/*/; do
  name="$(basename "$dir")"
  xxd -r -p "${dir}expected.hex" > "${EXP_OUT}/${name}.bin"
done

# ---- red-demo insertion point ----
# Sabotage for red demonstrations (corrupting or deleting an emitted file)
# goes HERE, in a scratchpad COPY of this script — never in this file.

fail=0

echo
echo "== anti-vacuity: emitted file sets vs corpus case list =="
(cd "$CORPUS_DIR" && ls -1d */ | sed 's#/$##') | sort > "${LISTS}/corpus"
(cd "$TS_OUT" && ls -1 | sed 's#\.bin$##') | sort > "${LISTS}/ts"
(cd "$EX_OUT" && ls -1 | sed 's#\.bin$##') | sort > "${LISTS}/ex"
if diff "${LISTS}/corpus" "${LISTS}/ts"; then
  echo "TS file set == corpus case list"
else
  echo "FAIL: TypeScript emitter produced a different file set than the corpus (see diff above)"
  fail=1
fi
if diff "${LISTS}/corpus" "${LISTS}/ex"; then
  echo "Elixir file set == corpus case list"
else
  echo "FAIL: Elixir emitter produced a different file set than the corpus (see diff above)"
  fail=1
fi

case_count="$(wc -l < "${LISTS}/corpus")"
if [ "$case_count" -lt 19 ]; then
  echo "FAIL: only ${case_count} corpus cases found (< 19) — corpus missing or wrong referent"
  fail=1
fi

echo
echo "== verdict A: cross-runtime diff -r (TS tree vs Elixir tree) =="
if diff -r "$TS_OUT" "$EX_OUT"; then
  echo "diff -r: no differences — TS and Elixir byte-identical on all ${case_count} cases (incl. 9xx)"
else
  echo "FAIL: TypeScript and Elixir emitted different bytes (see diff above)"
  fail=1
fi

echo
echo "== verdict B: per-case emitted bytes vs decoded expected.hex =="
nonxx_match=0
ninexx_mismatch=0
while IFS= read -r name; do
  ts_bin="${TS_OUT}/${name}.bin"
  ex_bin="${EX_OUT}/${name}.bin"
  exp_bin="${EXP_OUT}/${name}.bin"
  if [ -f "$ts_bin" ] && cmp -s "$ts_bin" "$exp_bin"; then
    bts="MATCH"
  else
    bts="MISMATCH"
  fi
  if [ -f "$ex_bin" ] && cmp -s "$ex_bin" "$exp_bin"; then
    bex="MATCH"
  else
    bex="MISMATCH"
  fi
  line="${name}: TS ${bts} / EX ${bex} vs expected"
  case "$name" in
    9*)
      if [ "$bts" = "MATCH" ] || [ "$bex" = "MATCH" ]; then
        echo "${line} — FAIL: this 9xx case is deliberately wrong and MUST mismatch; a match means the harness or corpus is broken"
        fail=1
      else
        echo "${line} (deliberate 9xx case — required)"
        ninexx_mismatch=$((ninexx_mismatch + 1))
      fi
      ;;
    *)
      if [ "$bts" = "MATCH" ] && [ "$bex" = "MATCH" ]; then
        echo "$line"
        nonxx_match=$((nonxx_match + 1))
      else
        echo "${line} — FAIL"
        for pair in "TS ${ts_bin}" "EX ${ex_bin}"; do
          rt="${pair%% *}"
          bin="${pair#* }"
          if [ -f "$bin" ] && ! cmp -s "$bin" "$exp_bin"; then
            echo "-- ${rt} vs expected (xxd diff):"
            diff <(xxd "$bin") <(xxd "$exp_bin") || true
          elif [ ! -f "$bin" ]; then
            echo "-- ${rt} emitted file ${name}.bin is missing"
          fi
        done
        fail=1
      fi
      ;;
  esac
done < "${LISTS}/corpus"

echo
echo "== summary =="
echo "cases in corpus:                       ${case_count}"
echo "cross-runtime (verdict A):             diff -r over ${case_count} emitted file pairs (see above)"
echo "non-9xx MATCH vs expected (verdict B): ${nonxx_match}"
echo "9xx MISMATCH vs expected (required):   ${ninexx_mismatch}"
echo "SELECTOR: green means: TS==Elixir==expected over the canonical-json corpus, ${case_count} cases; invalid-entries classification is covered by the unit suites, not this harness."

if [ "$fail" -ne 0 ]; then
  echo "RESULT: RED — at least one check above failed"
  exit 1
fi
echo "RESULT: GREEN"
