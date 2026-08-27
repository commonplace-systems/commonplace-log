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
# Usage:  bash scripts/check_gated_arms.sh [--update]
set -uo pipefail

cd "$(dirname "$0")/.." || exit 70
manifest=test/GATED_ARMS.txt
actual=$(mktemp) || exit 70
trap 'rm -f "$actual"' EXIT

emit() {
  local f count vars
  for f in $(grep -rl -e '^if System.get_env' -e '@moduletag skip' test/*.exs 2>/dev/null | sort); do
    count=$(grep -c '^[[:space:]]*test "' "$f")
    vars=$(grep -o 'System.get_env("[A-Z_][A-Z_]*")\|@[a-z_]*_var "[A-Z_][A-Z_]*"' "$f" \
           | grep -o '"[A-Z_][A-Z_]*"' | tr -d '"' | sort -u | tr '\n' ' ')
    if grep -q '^if System.get_env' "$f"; then
      printf '%s\tconditionally-compiled\t%s\t%s\n' "$f" "$count" "${vars% }"
    else
      printf '%s\tmoduletag-skip\t%s\t%s\n' "$f" "$count" "${vars% }"
    fi
  done
}

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

echo "GATED ARMS: OK — $(wc -l < "$manifest") gated module(s), matching the manifest."
echo "None of these run under a plain \`mix test\`. Run them explicitly:"
echo "  RUN_WRANGLER_INTEGRATION=1 COMMONPLACE_LOG_WORKER_DIR=../worker mix test test/wrangler_real_socket_integration_test.exs"
echo "  COMMONPLACE_LOG_GATEWAY_URL=<url> COMMONPLACE_LOG_GATEWAY_TOKEN=<token> mix test test/cloudflare_deployed_integration_test.exs"
