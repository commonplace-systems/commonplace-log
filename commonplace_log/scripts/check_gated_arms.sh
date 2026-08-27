#!/usr/bin/env bash
# Inventory of test modules that DO NOT RUN under a plain `mix test`, checked
# against a pinned manifest.
#
# WHY THIS EXISTS: on 2026-08-25 a real-socket arm of this suite was broken by
# an unrelated landing and stayed broken across two more landings, because a
# test module wrapped in a column-0 `if System.get_env(...) do` contributes
# ZERO to every number ExUnit prints — not "excluded", not "skipped", ABSENT.
# A @moduletag-skipped module at least prints "N skipped"; a conditionally
# compiled one is invisible to a total, to an exclusion count, and to the
# three-number protocol alike.
#
# This check is SOURCE-ONLY: it starts no BEAM and needs no test run.
# It fails when the set of gated modules differs from the manifest, so a new
# gated module cannot appear without someone writing down how it is run.
#
# Corpus and pattern defects found by commonplace-markdown (2026-08-27) and
# fixed here, each measured against this tree:
#   1. `test/*.exs` globs TOP LEVEL ONLY. Not live here today (26 of 26 test
#      files are top level) but silent and permanent the moment anyone adds
#      test/sub/foo_test.exs: the scan finds nothing and reports OK forever.
#      Now a recursive find.
#   2. `@moduletag skip` did not match `@moduletag :skip`, the ordinary Elixir
#      form. Measured: 0 hits on a module carrying it. Both forms now match.
#   3. A commented-out gate could be counted. Comments are stripped first.
# And a positive control, reached independently by markdown, log-reducer and
# biscuit: "there are no gated modules" and "I scanned nothing" print the same
# empty inventory, so the script refuses when its corpus is empty.
#
# Usage:  bash scripts/check_gated_arms.sh [--update]
set -uo pipefail

cd "$(dirname "$0")/.." || exit 70
manifest=test/GATED_ARMS.txt
actual=$(mktemp) || exit 70
scratch=$(mktemp) || exit 70
trap 'rm -f "$actual" "$scratch"' EXIT

# Every test file, at any depth. `-print0`/`read -d` so a path with a space
# cannot split a filename into two corpus entries.
corpus() {
  find test -name '*_test.exs' -type f -print0 | sort -z
}

# A file with its comment lines removed, so a commented-out gate is not counted.
uncommented() {
  sed 's/[[:space:]]*#.*$//' "$1"
}

emit() {
  local f count vars
  while IFS= read -r -d "" f; do
    uncommented "$f" > "$scratch"
    grep -qE '^(if|case) System.get_env' "$scratch" || grep -qE '@moduletag[[:space:]]+(:skip|skip:)' "$scratch" || continue
    count=$(grep -c '^[[:space:]]*test "' "$scratch")
    vars=$(grep -o 'System.get_env("[A-Z_][A-Z_]*")\|@[a-z_]*_var "[A-Z_][A-Z_]*"' "$scratch" \
           | grep -o '"[A-Z_][A-Z_]*"' | tr -d '"' | sort -u | tr '\n' ' ')
    if grep -qE '^(if|case) System.get_env' "$scratch"; then
      printf '%s\tconditionally-compiled\t%s\t%s\n' "$f" "$count" "${vars% }"
    else
      printf '%s\tmoduletag-skip\t%s\t%s\n' "$f" "$count" "${vars% }"
    fi
  done < <(corpus)
}

# CONTROL 1 (necessary, NOT sufficient). An empty inventory has two causes —
# nothing is gated, or the scan saw nothing — and they print identically.
corpus_size=$(corpus | tr -dc "\0" | wc -c)
if [ "$corpus_size" -eq 0 ]; then
  echo "GATED ARMS: REFUSE — scanned 0 test files. The corpus is empty, so an"
  echo "empty inventory would prove nothing. Check the glob and the working directory."
  exit 70
fi

# CONTROL 2, and it is the one that matters. boss-clod, 2026-08-27, after
# biscuit's scanner reported "0 gated modules, 10 files scanned" with a gated
# module sitting in a subdirectory: A NON-EMPTINESS CONTROL DETECTS A SCANNER
# THAT READ NOTHING; IT CANNOT DETECT ONE READING THE WRONG POPULATION. Ten
# top-level files existed, so "did I scan anything" answered yes while "did I
# scan everything" answered no — which is exactly the glob defect above, and
# Control 1 would NOT have caught it here either (26 top-level files exist).
#
# So enumerate the corpus a SECOND, INDEPENDENT WAY — the git index rather
# than the filesystem — and refuse when they disagree. Two enumerations of one
# population that must agree; a disagreement means one of them is wrong and
# neither verdict is trustworthy.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_size=$(git ls-files -- "test/*_test.exs" "test/**/*_test.exs" | sort -u | wc -l)
  if [ "$git_size" -ne "$corpus_size" ]; then
    echo "GATED ARMS: REFUSE — corpus disagreement: find sees ${corpus_size} test file(s),"
    echo "the git index sees ${git_size}. One enumeration is wrong, so no verdict drawn"
    echo "from either is trustworthy. (An untracked or ignored test file will do this.)"
    exit 70
  fi
fi

emit > "$actual"

if [ "${1:-}" = "--update" ]; then
  cp "$actual" "$manifest"
  echo "manifest updated:"; cat "$manifest"; exit 0
fi

if [ ! -f "$manifest" ]; then
  echo "GATED ARMS: no manifest at $manifest; run with --update after reviewing:"
  cat "$actual"; exit 66
fi

if ! diff -u "$manifest" "$actual"; then
  cat <<'MSG'

GATED ARMS: FAIL — the set of test modules that do not run under a plain
`mix test` has changed. Every line here is an arm no ordinary run exercises.
Decide how each is run, record it in docs/, then re-run with --update.
MSG
  exit 65
fi

echo "GATED ARMS: OK — $(wc -l < "$manifest") gated module(s) over $corpus_size test file(s), matching the manifest."
echo "None of these run under a plain \`mix test\`. Run them explicitly:"
echo "  RUN_WRANGLER_INTEGRATION=1 COMMONPLACE_LOG_WORKER_DIR=../worker mix test test/wrangler_real_socket_integration_test.exs"
echo "  COMMONPLACE_LOG_GATEWAY_URL=<url> COMMONPLACE_LOG_GATEWAY_TOKEN=<token> mix test test/cloudflare_deployed_integration_test.exs"
