#!/usr/bin/env bash
# Launch a Sol round in a tmux pane — refusing to launch NOTHING.
#
# LAUNCHER-NODE-1, 2026-09-04. Ported from commonplace-next/bin/dispatch-round.sh by hand, at
# plan's row 929, as a NAMED exception to "all implementation coding → Sol": a repo with no
# launcher cannot dispatch Sol until one exists.
#
# ⭐ WHAT IS UNCHANGED, AND WHY IT IS MOST OF THE FILE. The refusals below are language-agnostic
# and each one is a scar:
#   * empty/missing prompt — 2026-08-24: the prompt file was written by a link of an && chain that
#     never ran, the launcher dispatched an EMPTY prompt, and Sol asked "What would you like me to
#     work on?" and exited clean at 2.6k tokens. Cheap that time; a PARTIALLY written prompt is not.
#   * prompt does not name the round / under 100 words — the same defect caught earlier.
#   * HEAD on no remote ref — a round whose description exists on one disk is one you cannot rebuild.
#   * dirty worktree — a round must start from a committed state.
# ⛔ THE GOVERNING RULE, INHERITED VERBATIM: A DISPATCHER THAT CAN START A ROUND WHICH CANNOT PASS
#    MUST REFUSE TO.
#
# ⛔⛔ WHAT CHANGED, AND WHY THE ORIGINAL COULD NOT SIMPLY BE COPIED. next is Elixir; this repo's
# round surface is `worker/` — TypeScript on vitest-pool-workers. The three toolchain checks there
# (`mix deps.get`, `MIX_ENV=test mix compile`, and the non-empty `deps/` check that reads their
# result) mean NOTHING here. Their replacements are exact, and they matter MORE here, not less:
#     mix deps.get            →  npm ci        in worker/
#     MIX_ENV=test mix compile→  npx vitest run GREEN AT THE BASE
#     deps/ non-empty         →  worker/node_modules non-empty
#   ⚠️ A fresh `git clone` has NO `worker/node_modules` — it is gitignored. MEASURED 2026-09-04:
#   this door DELETED that directory to reclaim 510 MB, so "the host happens to have one" is not a
#   property anyone should rely on. A round dispatched without it fails every arm for a reason the
#   round did not cause. That is NEXT-RACE-B one repo over.
#
# ⛔⛔ AND THE BOX GATE IS A DIFFERENT SCRIPT ON PURPOSE — THIS IS THE PORT'S REAL FINDING.
#   next's bin/box-state.sh enumerates `pgrep -x beam.smp` and NOTHING ELSE (`grep -c node` = 0).
#   A round in THIS repo is node + workerd + vitest: it starts NO BEAM. ⇒ box-state.sh would report
#   a log round as an empty box, for its entire duration, to every door that asked.
#   ⚠️ AND `pgrep -x node` DOES NOT REPAIR IT: node names its main thread `MainThread`, so
#   /proc/PID/comm never says "node" and pgrep returns EMPTY FOR A HEALTHY PROCESS — absence with
#   more than one cause, inside the instrument built to catch exactly that.
#   ⭐ boss-clod's /home/jes/boss-clod/box-free.sh IS ALREADY REPAIRED for this (its own header
#   names biscuit's BACKUP-1b-i reading `FREE|0 suites` for its whole duration) and it reports
#   BUSY on non-BEAM tenancy. ⇒ THIS LAUNCHER GATES ON box-free.sh, NOT ON box-state.sh.
#   Contract: rc 0 FREE · rc 1 BUSY · rc 2 BLIND. ⛔ BLIND IS NOT FREE — it refuses.
# ⏳ RETIREMENT CONDITION: delete this note when box-state.sh enumerates non-BEAM tenancy itself,
#    or when the two scripts merge. A correct action defended by a dead reason keeps being taken
#    after it becomes wrong.
#
# Usage: bin/dispatch-round.sh <round-dir e.g. /home/jes/sol-realm-remove-1b> <round-name> [--preflight]
# ⚠️ --preflight IS NOT A NO-OP. It dispatches nothing (it exits before the tmux window) but it DOES
#    run `npm ci` and the full `npx vitest run` — real work on the shared box, and it runs the box
#    gate too, because a mode that exempts a refusal from itself cannot demonstrate it.
set -euo pipefail
dir="${1:?round dir}"; name="${2:?round name as it appears in the prompt}"; mode="${3:-}"
wt="$dir/wt"; prompt="$dir/prompt.txt"

[ -d "$wt/.git" ] || [ -f "$wt/.git" ] || { echo "REFUSED: no worktree at $wt" >&2; exit 64; }
[ -s "$prompt" ] || { echo "REFUSED: $prompt is missing or empty — nothing to dispatch." >&2; exit 65; }
grep -qF -- "$name" "$prompt" || { echo "REFUSED: prompt does not name the round '$name'." >&2; exit 65; }
[ "$(wc -w < "$prompt")" -ge 100 ] || { echo "REFUSED: prompt is $(wc -w < "$prompt") words; a real brief is longer." >&2; exit 65; }

base=$(git -C "$wt" rev-parse HEAD)
git -C "$wt" fetch -q origin
git -C "$wt" branch -r --contains "$base" | grep -q . || { echo "REFUSED: worktree HEAD $base is on no remote ref. Push first." >&2; exit 66; }
# ⛔ THE PLACED ARM. A round whose prompt asserts a file is present at the base must actually have
# it, or the implementer STOPs on a difference the DISPATCHER manufactured. Declared per round.
if [ -n "${REQUIRE_FILES:-}" ]; then
  for f in $REQUIRE_FILES; do
    [ -s "$wt/$f" ] || { echo "REFUSED: required file '$f' is missing or empty in the worktree — the prompt's corpus line claims it is present at the base." >&2; exit 70; }
  done
fi

# ⛔⛔ THE DIRTY CHECK TOLERATES EXACTLY THE DECLARED PLACED FILES, AND NOTHING ELSE.
# FOUND BY THIS SCRIPT'S OWN SELF-TEST, 2026-09-04, before it ever dispatched: a placed arm is by
# construction UNTRACKED, so a plain `git status --porcelain` emptiness test refuses every round
# that declares one. The two gates as first written were MUTUALLY EXCLUSIVE — REQUIRE_FILES
# demanded a file the dirty gate then refused — so a round that should pass COULD NEVER START.
# ⭐ The inverse of the rule this file is built on, and the self-test is the only reason it was not
# discovered by a failed dispatch: a gate never seen PASS on known-good input is as unproven as one
# never seen fail.
# ⚠️ The subtraction is BY EXACT PATH, and anything else dirty still refuses — the point is that a
# round starts from a committed state PLUS a declared, enumerated placement, not from "roughly clean".
dirty=$(git -C "$wt" status --porcelain)
if [ -n "${REQUIRE_FILES:-}" ]; then
  for f in $REQUIRE_FILES; do
    dirty=$(printf '%s\n' "$dirty" | grep -v -x -e "?? $f" -e " M $f" -e "M  $f" || true)
  done
fi
[ -z "$(printf '%s' "$dirty" | tr -d '[:space:]')" ] || {
  echo "REFUSED: worktree is dirty beyond the declared placed files; a round must start from a committed state." >&2
  printf '%s\n' "$dirty" >&2
  exit 67; }

# ⭐ Install and prove the base GREEN on the HOST before dispatch. The round never installs.
# `|| rc=$?`: under `set -e` a failing assignment exits BEFORE a following `rc=$?` — measured in
# next's launcher 2026-08-25 (the first form died rc=127 with no REFUSED line: dispatch prevented,
# verdict lost).
rc=0; out=$(cd "$wt/worker" && npm ci 2>&1) || rc=$?
[ "$rc" -eq 0 ] || { echo "$out" | tail -5; echo "REFUSED: npm ci failed on the host (rc=$rc); not dispatching a round that would install inside the fence." >&2; exit 68; }

[ -d "$wt/worker/node_modules" ] && [ "$(ls "$wt/worker/node_modules" 2>/dev/null | wc -l)" -gt 0 ] || {
  echo "REFUSED: $wt/worker/node_modules is missing or empty after npm ci — wrong referent, not a clean state." >&2; exit 68; }

# ⛔ GREEN AT THE BASE IS THE POINT, NOT "IT COMPILES". A red base makes every arm in the round
# unreadable: the implementer cannot tell its own failure from one it inherited.
rc=0; out=$(cd "$wt/worker" && npx vitest run 2>&1) || rc=$?
[ "$rc" -eq 0 ] || { echo "$out" | tail -15; echo "REFUSED: the suite is NOT green at the base (rc=$rc). A round dispatched onto a red base cannot report its own result." >&2; exit 68; }

# ⛔ AN UNWIRED GATE IS A REMEMBERED RULE. This one REFUSES; it does not print and proceed.
bf=/home/jes/boss-clod/box-free.sh
if [ -x "$bf" ]; then
  set +e; "$bf" >&2; brc=$?; set -e
  case "$brc" in
    0) : ;;
    1) echo "REFUSED: box-free says BUSY (see its line above)." >&2; exit 75 ;;
    *) echo "REFUSED: box-free says BLIND (rc=$brc) — no information is NOT permission." >&2; exit 75 ;;
  esac
  # ⭐ JITTER + RE-CHECK. `free` is a time-of-check/time-of-use race, and every door observing it
  # independently SYNCHRONISES its starts rather than separating them. The backoff is not the
  # protection; THE RE-CHECK is: the first door to wake starts, and every other door's second
  # observation sees it. ⚠️ Narrows the window, does not close it.
  # ⚠️ --preflight runs the gate but skips only the SLEEP: a delay is not a refusal.
  if [ "$mode" != "--preflight" ]; then
    sleep $(( RANDOM % 26 ))
    set +e; "$bf" >&2; brc=$?; set -e
    [ "$brc" -eq 0 ] || { echo "REFUSED: box-free cleared, then the re-check after jitter did not (rc=$brc) — another door started first." >&2; exit 75; }
  fi
else
  echo "REFUSED: $bf is not executable — the box is UNVERIFIED, and unverified is not clear." >&2; exit 75
fi

[ "$mode" = "--preflight" ] && { echo "PREFLIGHT OK: $dir would dispatch '$name' (suite green at $base)."; exit 0; }

win="$(basename "$dir")"
tmux new-window -d -t 0: -n "$win" -c "$dir" \
  "SOL_WORKDIR=$wt /home/jes/boss-clod/sol-egress-run.sh \"\$(cat $prompt)\" 2>&1 | tee $dir/sol-run.log; echo \"=== sol EXITED rc=\${PIPESTATUS[0]} ===\"; sleep 86400"
sleep 20
# ⭐ Verify on the RUNNING pids and capture the outer pid. NEWEST tree first (sorted by elapsed
# time): a finished round's wrapper can linger orphaned on the same clone and become outer.pid for
# the NEXT round — the waiter would then watch a corpse.
n=0
for pid in $(ps -eo etimes,pid,cmd | awk -v d="$wt" '/[c]odex exec -m gpt-5.6-sol/ && index($0,d) {print $1, $2}' | sort -n | awk '{print $2}'); do
  n=$((n+1))
  echo "$pid prompt=$(tr '\0' '\n' < /proc/$pid/cmdline | grep -cF -- "$name")"
  [ -z "${outer:-}" ] && outer=$pid && echo "$pid" > "$dir/outer.pid"
done
[ "$n" -gt 0 ] || { echo "NOT RUNNING: no codex process on $wt after 20s. Read $dir/sol-run.log." >&2; exit 1; }
echo "DISPATCHED $name in tmux window $win, outer pid $(cat "$dir/outer.pid"); wait on it by pid."
