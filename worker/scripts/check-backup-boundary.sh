#!/usr/bin/env bash
# Backup custody gates. Three arms with three dispositions; know which you ran.
#
# Durable arm (default, no arguments) — stays green under unrelated legitimate
# change, goes red on a real custody violation:
#   D4  hash-manifest custody of the complete reviewed production backup source
#       set (scripts/check-backup-output.py against
#       scripts/backup-output-review.json). Any edit or new module under
#       backup/ fails until its output paths are reviewed and the recorded
#       hashes are deliberately updated.
#
# Delegated arm (NOT run by this script):
#   A4  the write-surface scan (backup code references no realm-write surface;
#       live realm code is the positive control). Its single copy lives in
#       test/backup-boundary.test.ts, which CI runs on every push and pull
#       request via `npm test`. This script deliberately carries no second
#       copy of that regex: two copies is how they diverge.
#
# Review-time arm (runs ONLY with an explicit --review-base; no default base):
#   A6  zero diff from the reviewer-supplied pre-round commit across the live
#       worker config (wrangler.jsonc), the live entry module (src/index.ts)
#       and the commonplace_log/ tree — certifying that the round under review
#       leaves the live write surface untouched. This is a property of a
#       changeset against ITS OWN base, not of HEAD against any fixed commit,
#       so the reviewer must supply the base every time; a baked-in default
#       would turn every later legitimate change into a false alarm.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
usage: check-backup-boundary.sh [--review-base <commit>]

Without arguments: run the durable D4 arm — the hash-manifest custody gate
over the backup/ production sources. The A4 write-surface scan is not run
here; its single copy is test/backup-boundary.test.ts (CI runs it via
`npm test`).

--review-base <commit>
    Additionally run the review-time A6 arm: require zero diff from <commit>
    across wrangler.jsonc, src/index.ts and commonplace_log/. <commit> must
    be the pre-round base of the changeset you are reviewing (for example,
    the merge-base of the round's branch with main). There is deliberately
    no default: the property is meaningful only relative to a base the
    reviewer chose for this review.
EOF
}

review_base=""
while [ $# -gt 0 ]; do
  case "$1" in
    --review-base)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "check-backup-boundary: --review-base requires a commit: the pre-round base of the changeset under review." >&2
        exit 2
      fi
      review_base="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "check-backup-boundary: unknown argument '$1'." >&2
      echo "The A6 review-time arm takes an explicit --review-base <pre-round-commit>; there is no default or positional base." >&2
      usage >&2
      exit 2
      ;;
  esac
done

# D4 (durable): hash-manifest custody of the backup/ production source set.
python3 scripts/check-backup-output.py

# A4 (delegated): pointer only, so a reader of this output knows where that gate went.
echo "A4 NOT RUN HERE: the write-surface scan's single copy is test/backup-boundary.test.ts; CI runs it via 'npm test'."

if [ -z "$review_base" ]; then
  echo "A6 NOT RUN (review-time arm): when reviewing a round, pass --review-base <pre-round-commit> to require zero diff across wrangler.jsonc, src/index.ts and commonplace_log/."
  exit 0
fi

if ! git rev-parse --verify --quiet "${review_base}^{commit}" >/dev/null; then
  echo "A6 FAIL: '--review-base $review_base' does not name a commit in this repository." >&2
  exit 2
fi

if git diff --exit-code "$review_base" -- wrangler.jsonc src/index.ts ../commonplace_log/; then
  echo "A6 PASS: zero diff from reviewer-supplied base $review_base across wrangler.jsonc, src/index.ts and commonplace_log/ — the changeset under review leaves the live write surface untouched."
else
  cat >&2 <<EOF
A6 FAIL: the tree differs from reviewer-supplied base $review_base in
wrangler.jsonc, src/index.ts or commonplace_log/ (diff above). Interpret this
relative to YOUR base: if the diff is part of the round under review, that
round touches the live write surface and needs its own justification; if the
diff is unrelated work that landed after your base, the base is stale — re-run
with the round's actual pre-round commit.
EOF
  exit 1
fi
