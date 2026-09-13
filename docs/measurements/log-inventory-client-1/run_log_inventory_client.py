#!/usr/bin/env python3
"""Fresh-output compiler/native runner for the bounded log-inventory client seam."""
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
BEAM_ROOT = pathlib.Path(os.environ.get("LOG_INVENTORY_CLIENT_BEAM_ROOT", "/home/jes/codex-save-state-1/tmp/origin-receipt-1/_build/test/lib"))
ELIXIR = os.environ.get("LOG_INVENTORY_CLIENT_ELIXIR", "/home/jes/.asdf/installs/elixir/1.18.4-otp-27/bin/elixir")
BASE_COMMIT = "4fa621db5d257260118fbf649049402ff09b5ef6"
TEST_FILE = REPO / "commonplace_log/test/cloudflare_sidecar_log_inventory_test.exs"
SCRIPT_FILE = pathlib.Path(__file__).resolve().with_name("log_inventory_client.exs")
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
COMPILE_TIMEOUT = 120
CLEANUP_GRACE = 5
EXPECTED_TOTAL = 8

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


def source_files():
    files = sorted((REPO / "commonplace_log/lib").rglob("*.ex"))
    files += [TEST_FILE, SCRIPT_FILE, RUNNER_FILE, REPO / "commonplace_log/mix.lock"]
    return files


def hashes():
    return {
        "source": {str(path.relative_to(REPO)): sha256(path) for path in source_files()},
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
        "LOG_INVENTORY_CLIENT_TEST_FILE": str(TEST_FILE),
        "LOG_INVENTORY_CLIENT_OUTPUT": str(OUT),
    })
    return env


class RunnerSignal(Exception):
    pass


received_signal = None
received_signal_number = None
active_records = []


def receive_signal(signum, _frame):
    global received_signal, received_signal_number
    if received_signal is None:
        received_signal = signal.Signals(signum).name
        received_signal_number = signum
    raise RunnerSignal(received_signal)


def process_state(value, group=False):
    try:
        (os.killpg if group else os.kill)(value, 0)
        return "present"
    except ProcessLookupError:
        return "absent"
    except PermissionError:
        return "unknown"


def wait_group_state(pgid, timeout):
    deadline = time.monotonic() + timeout
    state = process_state(pgid, group=True)
    while state == "present" and time.monotonic() < deadline:
        time.sleep(0.05)
        state = process_state(pgid, group=True)
    return state


def terminate_group(record):
    process = record["process"]
    pgid = record["pgid"]
    if record["first_signal"] is None:
        record["first_signal"] = "SIGTERM"
    try:
        os.killpg(pgid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        process.wait(timeout=CLEANUP_GRACE)
    except subprocess.TimeoutExpired:
        pass
    group_state = wait_group_state(pgid, CLEANUP_GRACE)
    if group_state == "present":
        record["forced_kill"] = True
        try:
            os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            process.wait(timeout=CLEANUP_GRACE)
        except subprocess.TimeoutExpired:
            pass
        wait_group_state(pgid, CLEANUP_GRACE)


def run_group(argv, name, timeout):
    stdout_path = OUT / f"{name}-stdout"
    stderr_path = OUT / f"{name}-stderr"
    stdout_file = stdout_path.open("wb")
    stderr_file = stderr_path.open("wb")
    process = subprocess.Popen(
        argv,
        cwd=REPO,
        env=clean_env(),
        stdout=stdout_file,
        stderr=stderr_file,
        start_new_session=True,
    )
    record = {
        "name": name,
        "pid": process.pid,
        "pgid": os.getpgid(process.pid),
        "process": process,
        "timed_out": False,
        "forced_kill": False,
        "first_signal": None,
    }
    active_records.append(record)
    try:
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            record["timed_out"] = True
            terminate_group(record)
    finally:
        terminate_group(record)
        stdout_file.close()
        stderr_file.close()
        active_records.remove(record)
        record["rc"] = process.returncode
        record["pid_state"] = process_state(record["pid"])
        record["pgid_state"] = process_state(record["pgid"], group=True)
        record["pid_absent"] = record["pid_state"] == "absent"
        record["pgid_absent"] = record["pgid_state"] == "absent"
        record.pop("process")
    return record, stdout_path.read_text(errors="replace"), stderr_path.read_text(errors="replace")


app_commit = git("rev-parse", "HEAD")
base = git("rev-parse", f"{BASE_COMMIT}^{{commit}}")
if subprocess.run(["git", "merge-base", "--is-ancestor", base, app_commit], cwd=REPO).returncode:
    raise SystemExit("source is not based on the accepted client commit")
if not all(path.is_file() for path in source_files() + COMPILE_SOURCES):
    raise SystemExit("missing runner input")
beams = sorted(BEAM_ROOT.rglob("*.beam"))
if len(beams) != 847:
    raise SystemExit(f"cached BEAM input count mismatch: {len(beams)} != 847")
pre = hashes()
(OUT / "input-sha256.json").write_text(json.dumps(pre, indent=2, sort_keys=True) + "\n")
(OUT / "source-pins.json").write_text(json.dumps({
    "source_commit": app_commit,
    "accepted_base_commit": base,
    "test_file": str(TEST_FILE),
    "compile_sources": [str(path) for path in COMPILE_SOURCES],
    "beam_root": str(BEAM_ROOT),
    "cached_beam_count": len(beams),
    "expected_total": EXPECTED_TOTAL,
}, indent=2, sort_keys=True) + "\n")

beam_args = [part for ebin in sorted(BEAM_ROOT.glob("*/ebin")) for part in ("-pa", str(ebin))]
isolated = OUT / "isolated-ebin"
isolated.mkdir()
elixirc = str(pathlib.Path(ELIXIR).with_name("elixirc"))
compile_cmd = [elixirc, *beam_args, "-o", str(isolated), *[str(path) for path in COMPILE_SOURCES]]
test_cmd = [ELIXIR, *beam_args, "-pa", str(isolated), str(SCRIPT_FILE)]
(OUT / "command.json").write_text(json.dumps({
    "compile_argv": compile_cmd,
    "test_argv": test_cmd,
    "cwd": str(REPO),
    "source_commit": app_commit,
    "accepted_base_commit": base,
    "expected_total": EXPECTED_TOTAL,
    "compile_timeout_seconds": COMPILE_TIMEOUT,
    "test_timeout_seconds": CHILD_TIMEOUT,
    "cleanup_grace_seconds": CLEANUP_GRACE,
}, indent=2) + "\n")

compile_record = None
test_record = None
compile_stdout = ""
compile_stderr = ""
test_stdout = ""
test_stderr = ""
runner_error = None
previous_handlers = {
    signum: signal.signal(signum, receive_signal)
    for signum in (signal.SIGTERM, signal.SIGINT)
}
try:
    compile_record, compile_stdout, compile_stderr = run_group(compile_cmd, "compile", COMPILE_TIMEOUT)
    if compile_record["rc"] == 0:
        test_record, test_stdout, test_stderr = run_group(test_cmd, "test", CHILD_TIMEOUT)
except RunnerSignal:
    runner_error = "runner_signal"
except BaseException as error:
    runner_error = f"{type(error).__name__}: {error}"
finally:
    for record in list(active_records):
        terminate_group(record)
    (OUT / "compile-stdout").write_text(compile_stdout)
    (OUT / "compile-stderr").write_text(compile_stderr)
    (OUT / "stdout").write_text(test_stdout)
    (OUT / "stderr").write_text(test_stderr)
    try:
        post = hashes()
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

    records = [record for record in (compile_record, test_record) if record is not None]
    native_rc = None if compile_record is None else compile_record["rc"]
    if compile_record is not None and compile_record["rc"] == 0 and test_record is not None:
        native_rc = test_record["rc"]
    match = re.search(r"(?m)^\s*(\d+) tests?, (\d+) failures?", test_stdout)
    count_match = match is not None and int(match.group(1)) == EXPECTED_TOTAL and int(match.group(2)) == 0
    cleanup_ok = bool(records) and all(
        record["pid_absent"] and record["pgid_absent"] and not record["forced_kill"]
        for record in records
    )
    verdict_rc = 0 if native_rc == 0 and equal and count_match and cleanup_ok and runner_error is None else 125
    if received_signal_number is not None:
        verdict_rc = 128 + received_signal_number
    (OUT / "native-exit.json").write_text(json.dumps({
        "native_rc": native_rc,
        "compile": compile_record,
        "test": test_record,
        "received_signal": received_signal,
        "received_signal_number": received_signal_number,
        "runner_error": runner_error,
        "input_equal": equal,
        "count_match": count_match,
        "cleanup_ok": cleanup_ok,
        "timeout_seconds": CHILD_TIMEOUT,
        "cleanup_grace_seconds": CLEANUP_GRACE,
    }, indent=2, sort_keys=True) + "\n")
    (OUT / "verdict.json").write_text(json.dumps({
        "native_rc": native_rc,
        "verdict_rc": verdict_rc,
        "input_equal": equal,
        "count_match": count_match,
        "cleanup_ok": cleanup_ok,
        "runner_error": runner_error,
    }, indent=2, sort_keys=True) + "\n")
    for signum, handler in previous_handlers.items():
        signal.signal(signum, handler)
raise SystemExit(verdict_rc)
