#!/usr/bin/env bash
#
# A `mix test` run that SAMPLES THE BOX THROUGHOUT, refuses without a slot token,
# and can be exercised without running anything.
#
#   SERVE_PID=<pid> OUT_DIR=/tmp/run bash scripts/box_sampled_run.sh
#   QUIET_RUN_STUB_ACTION=1 …                 # green arm: proves the gate passes,
#                                             # STARTS NOTHING (see below)
#
# ⭐ WHY THE STUB EXISTS — read docs/measurements/2026-08-27-stale-retry-timeout-and-the-green-arm.md
# FOR A GATE THAT GUARDS AN ACTION, THE RED ARM IS CHEAP AND THE GREEN ARM *IS*
# THE ACTION. Demonstrating that this pre-flight does NOT refuse on correct state
# once meant letting it proceed — and proceeding is `mix test`. That demo ran an
# unslotted 154-second suite on a shared box on 2026-08-27 and was logged as a
# clean green, because a killed wrapper and a finished run both leave no process.
# ⇒ STUB THE ACTION, NOT THE THRESHOLD. Never demonstrate this gate by lowering
#   or raising FLOOR and letting the run proceed.
#
# ⚠️ The `suites` column keys on a `mix test` cmdline. It is NOT a load counter:
#   `elixir foo.exs`, `mix run`, `mix deps.get` and a long-lived serve are all
#   BEAMs it cannot see. `beams` and the serve I/O columns exist for that reason.
#
# The one run commonplace-log owes: does `property stale-retry safety`
# (merge_laws_test.exs:153) time out at REST, or only under contention?
#
# yelixer, 2026-08-27: a pre-flight answers "may I start"; only sampling
# DURING the run answers "what did the box do while I ran". Its pre/post pair
# read 4286/4351 MB around a run whose MINIMUM was 934 MB. So this samples
# throughout and reports the minimum beside the verdict.
#
# Whole run to a file, exit code captured, no summary-line filtering.
set -uo pipefail
# Outputs go to a scratch directory, NEVER into the repo. Override with OUT_DIR.
S="${OUT_DIR:-${TMPDIR:-/tmp}/commonplace-log-boxrun}"
mkdir -p "$S" || exit 70

# ============================================================================
# log, 2026-08-27, AFTER WALKING INTO IT: FOR A GATE THAT GUARDS AN ACTION, THE
# RED ARM IS CHEAP AND THE GREEN ARM *IS* THE ACTION.
#
# At 18:47:22Z I demonstrated the floor gate with two arms. The red arm forced
# the floor and refused, rc 75 — correct. The GREEN arm ran the same script at
# the REAL floor to show it does NOT refuse on correct state, per my own
# standing rule that a gate never seen green is not known to work. It did not
# refuse. NOT REFUSING IS PROCEEDING, AND PROCEEDING IS `mix test`: a 154 s
# unslotted suite ran 18:47:28-18:50:02Z under an outer `timeout 20` that killed
# the wrapper, printed "Terminated", and left `mix test` reparented and alive.
# I read the absence of a process as the absence of a run and reported
# "nothing running" twice afterwards. The artifact was on disk the whole time.
#
# THE FIX IS TO STUB THE ACTION, NOT THE THRESHOLD. A green demo must prove the
# pre-flight PASSED without proving it by executing the thing the pre-flight
# guards. Threshold-stubbing (what I did) still ends in the action.
QUIET_RUN_STUB_ACTION="${QUIET_RUN_STUB_ACTION:-0}"
if [ "$QUIET_RUN_STUB_ACTION" = "1" ]; then
  ACTION_DESC="STUBBED (true) — GREEN-ARM DEMO ONLY, NO SUITE STARTED"
else
  ACTION_DESC="timeout 1200 mix test — REAL RUN"
fi
run_action() {
  if [ "$QUIET_RUN_STUB_ACTION" = "1" ]; then
    echo "ACTION STUBBED: the pre-flight PASSED and nothing was started." >&2
    echo "  This arm proves the gate goes GREEN. It proves NOTHING about the suite." >&2
    # A stub that returns INSTANTLY leaves the sampler with zero ticks, so the
    # green arm exercises the gate and NOT the reporting path below it — and a
    # column that has never produced a number is not known to work. `sleep`
    # starts no BEAM and touches no disk, so the arm stays harmless while every
    # line the real run prints gets exercised.
    sleep "${QUIET_RUN_STUB_SECONDS:-4}"
  else
    timeout 1200 mix test
  fi
}
# ============================================================================
cd /home/jes/commonplace-log/commonplace_log || exit 70

suites() { local n=0 p c; for p in $(pgrep -x beam.smp); do
  c=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)
  case "$c" in *"-extra"*"mix"*"test"*) n=$((n+1));; esac; done; echo "$n"; }

# The standing `commonplace serve`, identified by comm + cwd, never by pattern:
# `pgrep -f commonplace-serve-pin` matched another repo's bash shell (2026-08-27).
# Its RSS oscillated 2605 -> 385 -> 317 -> 2768 -> 298 within ~30 minutes, a range
# larger than the whole suite population, so it is sampled alongside available.
# The standing `commonplace serve` to sample alongside the suite. There is no
# safe default: a WRONG pid reads as a healthy small process, so this is unset
# unless you pass it, and every serve-derived column then reports UNKNOWN
# rather than a number that looks fine. Find it by `comm` + /proc/PID/cwd —
# NEVER by `pgrep -f`, which matches the command issuing it.
SERVE="${SERVE_PID:-0}"
serve_rss() {
  if [ -d /proc/$SERVE ] && [ "$(cat /proc/$SERVE/comm 2>/dev/null)" = "beam.smp" ]; then
    awk '/VmRSS/{print int($2/1024)}' /proc/$SERVE/status 2>/dev/null
  else
    echo "-1"   # unverifiable, NOT zero
  fi
}
# biscuit, 2026-08-27: use VmHWM, not the largest RSS anyone happened to sample.
# A high-water mark only moves up, so it is a BOUND rather than a reading, and it
# does not depend on who was looking when the serve peaked. (2854 vs the sampled
# 2768 here — the sampled constant was optimistic by 86 MB.)
serve_hwm() {
  if [ -d /proc/$SERVE ] && [ "$(cat /proc/$SERVE/comm 2>/dev/null)" = "beam.smp" ]; then
    awk '/VmHWM/{print int($2/1024)}' /proc/$SERVE/status 2>/dev/null
  else
    echo "-1"
  fi
}

# plan, 2026-08-27: THE QUEUE IS AUTHORITATIVE; the box check is a safety
# interlock on top of it, and neither substitutes for the other. An empty box
# is permission from the HOST, not permission from the ORDERING — three doors
# read the first as the second at 18:31. My waiter clearing is NOT a slot.
# Made a mechanism rather than my discipline: this refuses without a token I
# create only when plan names me.
SLOT_TOKEN="$S/SLOT_GRANTED"
if [ ! -f "$SLOT_TOKEN" ]; then
  echo "REFUSES rc76: no slot token at $SLOT_TOKEN. The box being clear is permission from the host,"
  echo "not from the ordering. plan holds the queue; I am last in it. Create the token only when named."
  exit 76
fi
echo "SLOT: token present, granted $(cat "$SLOT_TOKEN")"
echo "MODE: $ACTION_DESC"

# markdown, 2026-08-27: `suites == 0` IS A CHECK, NOT A LOCK. Every door that
# observes it independently clears at the same instant, so the more disciplined
# everyone is about checking, the more precisely the starts CORRELATE. Four
# suites started within seconds that way at 18:31.
#
# This needs no lock and no coordinator — it is the standard collision-avoidance
# shape: RANDOMISED BACKOFF, THEN RE-CHECK. The jitter decorrelates the herd;
# the re-check is what actually protects, because it observes anyone who won.
# markdown, 2026-08-27: a floor written as two literals — one in the test, one
# in the message — refuses correctly and NAMES THE WRONG NUMBER when either
# moves. That is the two-edit defect, and I had it here fifteen minutes after
# citing it at another door. One constant, referenced everywhere.
SUITE_COST=500; FLOOR=1500
jitter=$(( RANDOM % 25 ))
echo "HERD BACKOFF: sleeping ${jitter}s before the pre-flight, to decorrelate from any door that cleared the same condition at the same instant."
sleep "$jitter"

pre_a=$(free -m | awk '/^Mem:/{print $7}'); pre_r=$(serve_rss)
pre_s=$(suites)
# biscuit: a pre-flight that reads and proceeds is indistinguishable from one
# that did not look. This one REFUSES.
if [ "$pre_s" -ne 0 ]; then
  echo "PRE-FLIGHT REFUSES: suites=${pre_s} at start — somebody else cleared the same window during my backoff. Not starting; the waiter can re-arm."
  exit 75
fi
if [ "$(( pre_a - SUITE_COST ))" -le "$FLOOR" ]; then
  echo "PRE-FLIGHT REFUSES: available ${pre_a}MB minus suite ${SUITE_COST} <= floor ${FLOOR}. Not starting."
  exit 75
fi
echo "PRE-FLIGHT $(date -u +%H:%M:%S)Z available=${pre_a}MB serve_rss=${pre_r}MB pessimistic_headroom=$(( pre_a - ($(serve_hwm) - pre_r) ))MB serve_hwm=$(serve_hwm)MB load1=$(cut -d' ' -f1 /proc/loadavg) suites>=$(suites) beams=$(pgrep -xc beam.smp)" | tee "$S/quiet.meta"

# commonplace, 2026-08-27, and it is the fix for this script's central defect:
# A SUITE COUNTER IS NOT A LOAD COUNTER. The `suites` column keys on a cmdline
# ("-extra … mix test"), so it counted ~13 four-second `mix test --self-test`
# invocations that mix REFUSED as a second "suite", while missing every load
# that mattered — a scratch-clone `mix deps.get` (cmdline says deps.get), a
# periodic `mix run` state-render cron, a full local `git clone`, and a live
# `commonplace serve` writing a 3.5 GB CubDB store mid-window. The timeouts
# this script investigates terminate in SQLite OPEN/CONFIGURE, so the question
# is I/O, and a BEAM count is the wrong population in both directions.
#
# serve_io reads the one process on this box doing sustained embedded-store
# work. It is one file read per tick and starts nothing. UNREADABLE is reported
# as UNKNOWN, never as 0 — an absent counter and an idle disk must not print
# the same, which is this script's whole house style.
serve_io() {
  if [ -r /proc/$SERVE/io ]; then
    awk '/^read_bytes/{r=$2} /^write_bytes/{w=$2} END{if(r=="")print "UNKNOWN UNKNOWN"; else print r" "w}' /proc/$SERVE/io
  else
    echo "UNKNOWN UNKNOWN"
  fi
}

# In-flight sampler: one line per second for the duration.
# columns: time available load1 suites serve_rss headroom serve_read serve_write beams
# yelixer, 2026-08-27: the `suites` column keys on `mix test`; a bare
# `elixir foo.exs` is a full BEAM and invisible to it. A SLOT PROTECTS THE BOX,
# AND THE BOX IS BEAMs, NOT SUITES. Both columns are kept: `suites` answers
# "is someone else running the same kind of thing", `beams` answers "what is
# actually on the box" — and tonight those were different populations.
( while :; do a=$(free -m | awk '/^Mem:/{print $7}'); r=$(serve_rss); h=$(serve_hwm)
    if [ "$r" = "-1" ] || [ "$h" = "-1" ]; then hd=UNKNOWN; else hd=$(( a - (h - r) )); fi
    echo "$(date -u +%H:%M:%S) $a $(cut -d' ' -f1 /proc/loadavg) $(suites) $r $hd $(serve_io) $(pgrep -xc beam.smp)"; sleep 1; done ) > "$S/quiet.samples" &
sampler=$!
# markdown, 2026-08-27: THE CLEANUP OF A SAMPLER MUST NEVER BE ABLE TO FAIL THE
# RUN IT WAS MEASURING. Its `kill; wait` under set -e exited 143/1 AFTER both
# suites had run and before printing a word about them. No `wait` here, `|| true`
# on the kill, and this script does not use `set -e` — three independent reasons.
trap 'kill "$sampler" 2>/dev/null || true' EXIT

rc=0
run_action > "$S/quiet.log" 2>&1 || rc=$?
kill "$sampler" 2>/dev/null || true

{
  echo "rc=$rc"
  echo "MODE: $ACTION_DESC"
  echo "POST $(date -u +%H:%M:%S)Z available=$(free -m | awk '/^Mem:/{print $7}')MB load1=$(cut -d' ' -f1 /proc/loadavg)"
  echo "samples=$(wc -l < "$S/quiet.samples")"
  # biscuit / log-reducer, 2026-08-27: REFUSE below two samples. Zero samples
  # and a quiet box are otherwise the same observable, and an empty file prints
  # "MINIMUM available  MB" — a blank where a number goes, which a hurried
  # reader completes rather than questions.
  n_samples=$(wc -l < "$S/quiet.samples")
  if [ "$n_samples" -lt 2 ]; then
    echo "SAMPLER REFUSES: only ${n_samples} sample(s). The box readings for this run are"
    echo "UNAVAILABLE, not favourable — do not attribute this run's result to a quiet box."
  else

  # next, 2026-08-27: a non-numeric line sorts ahead of every number, and the
  # bad reading is a PLAUSIBLE value from the wrong end — the direction nobody
  # audits. Filter to integers before any min/max.
  ints() { awk -v c="$1" '{print $c}' "$S/quiet.samples" | grep -E '^-?[0-9]+$'; }
  unknown=$(awk '{print $6}' "$S/quiet.samples" | grep -c UNKNOWN || true)
  echo "available          MIN during run = $(ints 2 | sort -n  | head -1) MB"
  if [ "$unknown" -gt 0 ]; then
    echo "pessimistic headroom MIN during run = UNKNOWN for $unknown of $(wc -l < "$S/quiet.samples") samples"
    echo "  (serve pid unverifiable in those samples — the term is UNKNOWN, deliberately NOT computed as a comfortable number)"
  else
    echo "pessimistic headroom MIN during run = $(ints 6 | sort -n | head -1) MB   <- decides whether a red is attributable"
  fi
  echo "serve_rss          MAX during run = $(ints 5 | sort -rn | head -1) MB"
  # The delta, not the level: a counter's absolute value says nothing about the window.
  io_first=$(awk '$7 ~ /^[0-9]+$/{print $7; exit}' "$S/quiet.samples")
  io_last=$(awk '$7 ~ /^[0-9]+$/{last=$7} END{print last}' "$S/quiet.samples")
  iow_first=$(awk '$8 ~ /^[0-9]+$/{print $8; exit}' "$S/quiet.samples")
  iow_last=$(awk '$8 ~ /^[0-9]+$/{last=$8} END{print last}' "$S/quiet.samples")
  if [ -n "$io_first" ] && [ -n "$io_last" ]; then
    echo "serve DISK READ  during run = $(( (io_last - io_first) / 1024 )) KiB   <- the neighbour a BEAM count cannot see"
    echo "serve DISK WRITE during run = $(( (iow_last - iow_first) / 1024 )) KiB"
  else
    echo "serve DISK I/O   during run = UNKNOWN (counter unreadable) — NOT zero, and not evidence of a quiet disk"
  fi
  echo "load1              MAX during run = $(awk '{print $3}' "$S/quiet.samples" | grep -E '^[0-9.]+$' | sort -rn | head -1)"
  echo "suites             MAX during run = $(ints 4 | sort -rn | head -1)"
  echo "BEAMs              MAX during run = $(ints 9 | sort -rn | head -1)   <- what a slot actually rations"
  echo "WINDOW COVERAGE: sampler started BEFORE mix test and killed after it — covers the WHOLE run."
  echo "  (next, 2026-08-27: a sampler started late is a partial instrument that reads exactly like a complete one.)"
  fi
} | tee -a "$S/quiet.meta"

echo "--- summary line (plural-safe pattern):"
grep -E "[0-9]+ (doctests?|tests?|properties|failures?)" "$S/quiet.log" | tail -2
echo "--- failure blocks, if any:"
sed -n '/^  [0-9])/,/^$/p' "$S/quiet.log" | head -40 || true
