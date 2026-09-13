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


def terminate_group(record):
    process = record["process"]
    if process.poll() is not None:
        return
    record["first_signal"] = record["first_signal"] or "SIGTERM"
    try:
        os.killpg(record["pgid"], signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=CLEANUP_GRACE)
    except subprocess.TimeoutExpired:
        record["forced_kill"] = True
        try:
            os.killpg(record["pgid"], signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=CLEANUP_GRACE)


def absent(pid, pgid):
    def exists(value, group=False):
        try:
            (os.killpg if group else os.kill)(value, 0)
            return True
        except (ProcessLookupError, PermissionError):
            return False
    return not exists(pid) and not exists(pgid, True)


def run_group(argv, name, timeout):
    env = clean_env()
    process = subprocess.Popen(
        argv, cwd=REPO, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, start_new_session=True,
    )
    pgid = os.getpgid(process.pid)
    record = {"name": name, "pid": process.pid, "pgid": pgid, "process": process,
              "timed_out": False, "forced_kill": False, "first_signal": None}
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        record["timed_out"] = True
        stdout, stderr = error.stdout or "", error.stderr or ""
        terminate_group(record)
        tail_out, tail_err = process.communicate()
        stdout += tail_out or ""
        stderr += tail_err or ""
    finally:
        terminate_group(record)
        record["rc"] = process.returncode
        record["pid_absent"], record["pgid_absent"] = absent(record["pid"], record["pgid"])
        record.pop("process")
    return record, stdout, stderr


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
    "compile_argv": compile_cmd, "test_argv": test_cmd, "cwd": str(REPO),
    "source_commit": app_commit, "accepted_base_commit": base,
    "expected_total": EXPECTED_TOTAL, "compile_timeout_seconds": COMPILE_TIMEOUT,
    "test_timeout_seconds": CHILD_TIMEOUT, "cleanup_grace_seconds": CLEANUP_GRACE,
}, indent=2) + "\n")

compile_record, compile_stdout, compile_stderr = run_group(compile_cmd, "compile", COMPILE_TIMEOUT)
(OUT / "compile-stdout").write_text(compile_stdout)
(OUT / "compile-stderr").write_text(compile_stderr)
if compile_record["rc"] == 0:
    test_record, test_stdout, test_stderr = run_group(test_cmd, "test", CHILD_TIMEOUT)
else:
    test_record, test_stdout, test_stderr = None, "", ""
(OUT / "stdout").write_text(test_stdout)
(OUT / "stderr").write_text(test_stderr)

post = hashes()
(OUT / "input-sha256-post.json").write_text(json.dumps(post, indent=2, sort_keys=True) + "\n")
equal = post == pre
(OUT / "input-equality.json").write_text(json.dumps({"equal": equal, "input_count": len(pre["source"]) + len(pre["cached_beams"])}, indent=2) + "\n")
records = [compile_record] + ([test_record] if test_record else [])
for record in records:
    record.pop("process", None)
native_rc = compile_record["rc"] if compile_record["rc"] != 0 else test_record["rc"]
count_match = False
if test_record and test_record["rc"] == 0:
    match = re.search(r"(?m)^\s*(\d+) tests?, (\d+) failures?", test_stdout)
    count_match = match is not None and int(match.group(1)) == EXPECTED_TOTAL and int(match.group(2)) == 0
cleanup_ok = all(r["pid_absent"] and r["pgid_absent"] and not r["forced_kill"] for r in records)
verdict_rc = 0 if native_rc == 0 and equal and count_match and cleanup_ok else 125
(OUT / "native-exit.json").write_text(json.dumps({
    "native_rc": native_rc, "compile": compile_record, "test": test_record,
    "input_equal": equal, "count_match": count_match, "cleanup_ok": cleanup_ok,
    "timeout_seconds": CHILD_TIMEOUT, "cleanup_grace_seconds": CLEANUP_GRACE,
}, indent=2, sort_keys=True) + "\n")
(OUT / "verdict.json").write_text(json.dumps({
    "native_rc": native_rc, "verdict_rc": verdict_rc,
    "input_equal": equal, "count_match": count_match, "cleanup_ok": cleanup_ok,
}, indent=2, sort_keys=True) + "\n")
raise SystemExit(verdict_rc)
