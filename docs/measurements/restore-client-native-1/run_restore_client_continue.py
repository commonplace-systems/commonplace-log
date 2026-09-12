import hashlib
import json
import os
import pathlib
import re
import signal
import subprocess
import sys


repo = pathlib.Path(__file__).resolve().parents[3]
out = pathlib.Path(sys.argv[1]).resolve()
if out.exists():
    raise SystemExit(f"refusing existing output: {out}")
out.mkdir(parents=True)

parent_out = pathlib.Path(os.environ.get(
    "RESTORE_CLIENT_PARENT_OUTPUT",
    str(repo / "tmp/restore-client-native-2"),
)).resolve()
parent_pins = parent_out / "source-pins.json"
parent_isolated = parent_out / "isolated-ebin"
if not parent_pins.is_file() or not parent_isolated.is_dir():
    raise SystemExit(f"missing retained native-2 compiler output: {parent_out}")

pins = json.loads(parent_pins.read_text())
beam_root = pathlib.Path(os.environ.get("RESTORE_CLIENT_BEAM_ROOT", pins["beam_root"]))
elixir = os.environ.get(
    "RESTORE_CLIENT_ELIXIR",
    "/home/jes/.asdf/installs/elixir/1.18.4-otp-27/bin/elixir",
)
source_commit = subprocess.check_output(
    ["git", "rev-parse", "HEAD"], cwd=repo, text=True
).strip()
parent_commit = pins["source_commit"]
test_file = repo / "commonplace_log/test/restore_bundle_client_test.exs"
runner_file = pathlib.Path(__file__).resolve()
script_file = runner_file.with_name("restore_client_continue.exs")
original_script = runner_file.with_name("restore_client.exs")
source_files = sorted((repo / "commonplace_log/lib").rglob("*.ex"))
cached_beams = sorted(beam_root.rglob("*.beam"))
retained_beams = sorted(parent_isolated.rglob("*.beam"))
if not cached_beams or not retained_beams:
    raise SystemExit("missing cached or retained BEAM inputs")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def hashes():
    return {
        "source": {
            str(path.relative_to(repo)): sha256(path)
            for path in source_files + [test_file, original_script, script_file, runner_file]
        },
        "cached_beams": {str(path): sha256(path) for path in cached_beams},
        "retained_isolated_beams": {str(path): sha256(path) for path in retained_beams},
    }


pre = hashes()
(out / "input-sha256.json").write_text(json.dumps(pre, indent=2, sort_keys=True) + "\n")
(out / "source-pins.json").write_text(json.dumps({
    "source_commit": source_commit,
    "parent_native_source_commit": parent_commit,
    "parent_output": str(parent_out),
    "beam_root": str(beam_root),
    "retained_isolated_ebin": str(parent_isolated),
    "target_tag": "restore_oversized_response",
    "expected_tests": 1,
    "expected_failures": 0,
}, indent=2, sort_keys=True) + "\n")

beam_args = [part for ebin in sorted(beam_root.glob("*/ebin")) for part in ("-pa", str(ebin))]
elixir_cmd = [elixir, *beam_args, "-pa", str(parent_isolated), str(script_file)]
(out / "command.json").write_text(json.dumps({
    "argv": elixir_cmd,
    "cwd": str(repo),
    "source_commit": source_commit,
    "parent_native_source_commit": parent_commit,
    "parent_output": str(parent_out),
    "target_tag": "restore_oversized_response",
    "timeout_seconds": 120,
    "term_grace_seconds": 5,
    "compile": False,
}, indent=2) + "\n")


def text(value):
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode(errors="replace")
    return value


def run_group(argv):
    process = subprocess.Popen(
        argv,
        cwd=repo,
        env={**os.environ, "RESTORE_CLIENT_TEST_FILE": str(test_file)},
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=120)
        return process.returncode, text(stdout), text(stderr), False, None
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, stderr = process.communicate()
        return process.returncode, text(stdout), text(stderr), True, 124


native_rc = None
timed_out = False
stdout = stderr = ""
try:
    native_rc, stdout, stderr, timed_out, timeout_rc = run_group(elixir_cmd)
    (out / "stdout").write_text(stdout)
    (out / "stderr").write_text(stderr)
finally:
    (out / "stdout").write_text(stdout)
    (out / "stderr").write_text(stderr)
    post = hashes()
    (out / "input-sha256-post.json").write_text(json.dumps(post, indent=2, sort_keys=True) + "\n")
    equal = post == pre
    (out / "input-equality.json").write_text(json.dumps({"equal": equal}, indent=2) + "\n")
    match = re.search(r"(?m)^\s*(\d+) tests?, (\d+) failures?", stdout)
    count_ok = match is not None and int(match.group(1)) == 1 and int(match.group(2)) == 0
    verdict = 125 if not equal or not count_ok else (timeout_rc if timed_out else native_rc)
    (out / "native-exit.json").write_text(json.dumps({
        "native_exit": native_rc,
        "timeout_exit": timeout_rc if timed_out else None,
        "timed_out": timed_out,
        "count_ok": count_ok,
        "expected_tests": 1,
        "expected_failures": 0,
    }) + "\n")
    (out / "verdict.json").write_text(json.dumps({
        "native_exit": native_rc,
        "verdict_exit": verdict,
        "input_equal": equal,
        "count_ok": count_ok,
    }) + "\n")

print(stdout)
print(stderr, file=sys.stderr)
raise SystemExit(verdict)
