#!/usr/bin/env python3
"""Single-owned-child compiler and native runner for empty restore entries."""
import hashlib
import json
import os
import pathlib
import re
import signal
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parents[3]
OUT = pathlib.Path(sys.argv[1]).resolve()
BEAM_ROOT = pathlib.Path(os.environ.get("RESTORE_CLIENT_EMPTY_ENTRIES_BEAM_ROOT", "/home/jes/codex-save-state-1/tmp/origin-receipt-1/_build/test/lib"))
ELIXIR = pathlib.Path(os.environ.get("RESTORE_CLIENT_EMPTY_ENTRIES_ELIXIR", "/home/jes/.asdf/installs/elixir/1.18.4-otp-27/bin/elixir"))
ERLANG_BIN = pathlib.Path(os.environ.get("RESTORE_CLIENT_EMPTY_ENTRIES_ERLANG_BIN", "/home/jes/.asdf/installs/erlang/27.3.4.8/bin"))
BASE_COMMIT = "32c1889"
TEST_FILE = REPO / "commonplace_log/test/restore_bundle_client_test.exs"
SCRIPT_FILE = pathlib.Path(__file__).resolve().with_name("restore_client_empty_entries.exs")
RUNNER_FILE = pathlib.Path(__file__).resolve()
SOURCE_FILE = REPO / "commonplace_log/lib/commonplace/log/persistence/cloudflare_sidecar.ex"
COMPILE_SOURCES = [
    REPO / "commonplace_log/lib/commonplace/log/jcs.ex",
    REPO / "commonplace_log/lib/commonplace/log/entry.ex",
    REPO / "commonplace_log/lib/commonplace/log/persistence.ex",
    REPO / "commonplace_log/lib/commonplace/log/persistence/cloudflare_sidecar/transport.ex",
    REPO / "commonplace_log/lib/commonplace/log/persistence/cloudflare_sidecar/httpc.ex",
    SOURCE_FILE,
]
CHILD_TIMEOUT = 180
CLEANUP_GRACE = 5
EXPECTED_TOTAL = 9
EXPECTED_EXCLUDED = 7

if OUT.exists():
    raise SystemExit(f"refusing existing output: {OUT}")
OUT.mkdir(parents=True)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git(*args):
    return subprocess.check_output(["git", *args], cwd=REPO, text=True).strip()


def all_inputs():
    return sorted((REPO / "commonplace_log/lib").rglob("*.ex")) + [
        TEST_FILE,
        SCRIPT_FILE,
        RUNNER_FILE,
        REPO / "commonplace_log/mix.lock",
    ]


def input_manifest():
    return {
        "source": {str(path.relative_to(REPO)): sha256(path) for path in all_inputs()},
        "cached_beams": {str(path): sha256(path) for path in sorted(BEAM_ROOT.rglob("*.beam"))},
    }


def clean_env():
    env = os.environ.copy()
    for key in list(env):
        upper = key.upper()
        if any(secret in upper for secret in ("TOKEN", "PASSWORD", "SECRET", "PRIVATE_KEY", "API_KEY")):
            env.pop(key, None)
    env.update({
        "MIX_ENV": "test",
        "RESTORE_CLIENT_EMPTY_ENTRIES_TEST_FILE": str(TEST_FILE),
        "RESTORE_CLIENT_EMPTY_ENTRIES_COMPILE_SOURCES": json.dumps([str(path) for path in COMPILE_SOURCES]),
    })
    env["PATH"] = os.pathsep.join([str(ELIXIR.parent), str(ERLANG_BIN), env.get("PATH", "")])
    return env


def group_state(pgid):
    try:
        os.killpg(pgid, 0)
        return "present"
    except ProcessLookupError:
        return "absent"
    except PermissionError:
        return "unknown"


def process_state(pid):
    try:
        os.kill(pid, 0)
        return "present"
    except ProcessLookupError:
        return "absent"
    except PermissionError:
        return "unknown"


def wait_group_absent(pgid, timeout):
    deadline = time.monotonic() + timeout
    state = group_state(pgid)
    while state == "present" and time.monotonic() < deadline:
        time.sleep(0.05)
        state = group_state(pgid)
    return state


class RunnerSignal(Exception):
    pass


received_signal = None
received_signal_number = None


def latch_signal(signum):
    global received_signal, received_signal_number
    if received_signal is None:
        received_signal = signal.Signals(signum).name
        received_signal_number = signum


def receive_signal(signum, _frame):
    latch_signal(signum)
    raise RunnerSignal(received_signal)


def stop_owned_child(proc, pgid, forced_kill=False):
    first_signal = "SIGTERM"
    try:
        os.killpg(pgid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        proc.wait(timeout=CLEANUP_GRACE)
    except subprocess.TimeoutExpired:
        pass
    state = wait_group_absent(pgid, CLEANUP_GRACE)
    if state == "present":
        forced_kill = True
        try:
            os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            proc.wait(timeout=CLEANUP_GRACE)
        except subprocess.TimeoutExpired:
            pass
        wait_group_absent(pgid, CLEANUP_GRACE)
    return first_signal, forced_kill


app_commit = git("rev-parse", "HEAD")
base_commit = git("rev-parse", f"{BASE_COMMIT}^{{commit}}")
if subprocess.run(["git", "merge-base", "--is-ancestor", base_commit, app_commit], cwd=REPO).returncode:
    raise SystemExit("source is not based on the accepted client commit")
if not all(path.is_file() for path in all_inputs() + COMPILE_SOURCES):
    raise SystemExit("missing runner input")
beams = sorted(BEAM_ROOT.rglob("*.beam"))
if len(beams) != 847:
    raise SystemExit(f"cached BEAM input count mismatch: {len(beams)} != 847")
pre = input_manifest()
(OUT / "input-sha256.json").write_text(json.dumps(pre, indent=2, sort_keys=True) + "\n")
(OUT / "source-pins.json").write_text(json.dumps({
    "source_commit": app_commit,
    "accepted_base_commit": base_commit,
    "test_file": str(TEST_FILE),
    "compile_sources": [str(path) for path in COMPILE_SOURCES],
    "beam_root": str(BEAM_ROOT),
    "elixir": str(ELIXIR),
    "erlang_bin": str(ERLANG_BIN),
    "cached_beam_count": len(beams),
    "expected_total": EXPECTED_TOTAL,
    "expected_excluded": EXPECTED_EXCLUDED,
    "selected_tag": "restore_empty_entries",
}, indent=2, sort_keys=True) + "\n")

beam_args = [part for ebin in sorted(BEAM_ROOT.glob("*/ebin")) for part in ("-pa", str(ebin))]
cmd = [str(ELIXIR), *beam_args, str(SCRIPT_FILE), str(OUT)]
(OUT / "command.json").write_text(json.dumps({
    "argv": cmd,
    "cwd": str(REPO),
    "source_commit": app_commit,
    "accepted_base_commit": base_commit,
    "compile_sources": [str(path) for path in COMPILE_SOURCES],
    "elixir": str(ELIXIR),
    "erlang_bin": str(ERLANG_BIN),
    "expected_total": EXPECTED_TOTAL,
    "expected_excluded": EXPECTED_EXCLUDED,
    "selected_tag": "restore_empty_entries",
    "timeout_seconds": CHILD_TIMEOUT,
    "cleanup_grace_seconds": CLEANUP_GRACE,
    "compile_and_tests_in_one_owned_child": True,
}, indent=2) + "\n")

env = clean_env()
proc = None
pid = None
pgid = None
first_signal = None
forced_kill = False
timed_out = False
cleanup_hold = None
runner_error = None
native_rc = None
verdict_rc = 125
previous_handlers = {}
stdout_path = OUT / "stdout"
stderr_path = OUT / "stderr"

try:
    for signum in (signal.SIGTERM, signal.SIGINT):
        previous_handlers[signum] = signal.signal(signum, receive_signal)

    launch_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT})
    stdout_file = stdout_path.open("wb")
    stderr_file = stderr_path.open("wb")
    try:
        proc = subprocess.Popen(
            cmd,
            cwd=REPO,
            env=env,
            stdout=stdout_file,
            stderr=stderr_file,
            start_new_session=True,
            preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, launch_mask),
        )
        pid = proc.pid
        pgid = pid
        try:
            pgid = os.getpgid(pid)
        except ProcessLookupError:
            # start_new_session makes the child leader its own process group;
            # retain that leader identity if it exits before registration.
            pgid = pid
        try:
            sid = os.getsid(pid)
        except ProcessLookupError:
            sid = None
        (OUT / "process-start.json").write_text(
            json.dumps({"pid": pid, "pgid": pgid, "sid": sid}) + "\n"
        )
    finally:
        stdout_file.close()
        stderr_file.close()
        signal.pthread_sigmask(signal.SIG_SETMASK, launch_mask)

    try:
        proc.wait(timeout=CHILD_TIMEOUT)
    except subprocess.TimeoutExpired:
        timed_out = True
        first_signal, forced_kill = stop_owned_child(proc, pgid, forced_kill)
except RunnerSignal:
    runner_error = "runner_signal"
except BaseException as error:
    runner_error = f"{type(error).__name__}: {error}"
finally:
    cleanup_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT})
    try:
        if proc is not None and pgid is not None:
            if group_state(pgid) == "present":
                signal_name, forced_kill = stop_owned_child(proc, pgid, forced_kill)
                first_signal = first_signal or signal_name
            try:
                proc.wait(timeout=CLEANUP_GRACE)
            except subprocess.TimeoutExpired:
                forced_kill = True
            native_rc = proc.returncode
            final_group_state = wait_group_absent(pgid, CLEANUP_GRACE)
            if final_group_state != "absent":
                cleanup_hold = f"owned process group {final_group_state}"
        pending = signal.sigpending()
        for signum in (signal.SIGTERM, signal.SIGINT):
            if signum in pending or signal.Signals(signum) in pending:
                latch_signal(signum)
        for signum in (signal.SIGTERM, signal.SIGINT):
            signal.signal(signum, lambda signum, _frame: latch_signal(signum))
        signal.pthread_sigmask(signal.SIG_SETMASK, cleanup_mask)
        cleanup_mask = None
        try:
            post = input_manifest()
            manifest_error = None
        except BaseException as error:
            post = {"manifest_error": f"{type(error).__name__}: {error}"}
            manifest_error = post["manifest_error"]
        (OUT / "input-sha256-post.json").write_text(json.dumps(post, indent=2, sort_keys=True) + "\n")
        equal = manifest_error is None and post == pre
        (OUT / "input-equality.json").write_text(json.dumps({
            "equal": equal,
            "input_count": len(pre["source"]) + len(pre["cached_beams"]),
            "manifest_error": manifest_error,
        }, indent=2) + "\n")
        pid_state = process_state(pid) if pid is not None else "absent"
        pgid_state = group_state(pgid) if pgid is not None else "absent"
        cleanup_ok = pid_state == "absent" and pgid_state == "absent" and cleanup_hold is None and not forced_kill
        stdout = stdout_path.read_text(errors="replace") if stdout_path.exists() else ""
        match = re.search(r"(?m)^\s*(\d+) tests?, (\d+) failures?", stdout)
        count_match = match is not None and int(match.group(1)) == EXPECTED_TOTAL and int(match.group(2)) == 0
        expected_app_result = {
            "total": EXPECTED_TOTAL,
            "failures": 0,
            "excluded": EXPECTED_EXCLUDED,
            "skipped": 0,
            "expected_total": EXPECTED_TOTAL,
            "expected_excluded": EXPECTED_EXCLUDED,
            "expected_failures": 0,
            "status": "expected",
        }
        try:
            app_result_match = json.loads((OUT / "app-result.json").read_text()) == expected_app_result
        except (OSError, ValueError):
            app_result_match = False
        verdict_rc = 0 if native_rc == 0 and not timed_out and equal and count_match and app_result_match and cleanup_ok and runner_error is None else 125
        if received_signal_number is not None:
            verdict_rc = 128 + received_signal_number
        process_record = {
            "pid": pid,
            "pgid": pgid,
            "native_rc": native_rc,
            "timed_out": timed_out,
            "received_signal": received_signal,
            "received_signal_number": received_signal_number,
            "first_signal": first_signal,
            "forced_kill": forced_kill,
            "cleanup_hold": cleanup_hold,
            "pid_state": pid_state,
            "pgid_state": pgid_state,
            "pid_absent": pid_state == "absent",
            "pgid_absent": pgid_state == "absent",
            "timeout_seconds": CHILD_TIMEOUT,
            "cleanup_grace_seconds": CLEANUP_GRACE,
            "count_match": count_match,
            "app_result_match": app_result_match,
            "input_equal": equal,
            "runner_error": runner_error,
        }
        (OUT / "native.rc").write_text("absent\n" if proc is None else f"{native_rc}\n")
        (OUT / "native-exit.json").write_text(json.dumps(process_record, indent=2, sort_keys=True) + "\n")
        (OUT / "verdict.json").write_text(json.dumps({
            "native_rc": native_rc,
            "verdict_rc": verdict_rc,
            "timed_out": timed_out,
            "input_equal": equal,
            "count_match": count_match,
            "app_result_match": app_result_match,
            "cleanup_ok": cleanup_ok,
            "runner_error": runner_error,
        }, indent=2, sort_keys=True) + "\n")
        (OUT / "verdict.rc").write_text(f"{verdict_rc}\n")
    finally:
        for signum in (signal.SIGTERM, signal.SIGINT):
            signal.signal(signum, signal.SIG_IGN)
        if cleanup_mask is not None:
            signal.pthread_sigmask(signal.SIG_SETMASK, cleanup_mask)
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)

raise SystemExit(verdict_rc)
