#!/usr/bin/env python3
"""Real loopback Httpc -> Wrangler -> SQLite/DO inventory workflow runner."""

import hashlib
import json
import os
import pathlib
import signal
import socket
import subprocess
import sys
import tarfile
import time


PROVIDER_ROOT = pathlib.Path(__file__).resolve().parents[3]
CLIENT_ROOT = pathlib.Path(os.environ.get(
    "LOG_INVENTORY_CLIENT_ROOT", "/home/jes/commonplace-log-restore-client-inventory"
)).resolve()
OUTPUT = pathlib.Path(sys.argv[1]).resolve()
EXPECTED_PROVIDER_PRODUCT = "804c4d43d7d56ed16942ea365733bd30e0674eaa"
CLIENT_COMMIT = os.environ.get("LOG_INVENTORY_CLIENT_COMMIT")
if CLIENT_COMMIT is None or len(CLIENT_COMMIT) != 40:
    raise SystemExit("LOG_INVENTORY_CLIENT_COMMIT must be the accepted full client source SHA")
if OUTPUT.exists():
    raise SystemExit(f"refusing existing output: {OUTPUT}")
OUTPUT.mkdir(parents=True)

BEAM_ROOT = pathlib.Path(os.environ.get(
    "LOG_INVENTORY_BEAM_ROOT",
    "/home/jes/codex-save-state-1/tmp/origin-receipt-1/_build/test/lib",
)).resolve()
WORKER_DEPS = pathlib.Path(
    os.environ.get("LOG_INVENTORY_WORKER_DEPS", "/home/jes/commonplace-log/worker/node_modules")
).resolve()
ELIXIR = os.environ.get(
    "LOG_INVENTORY_ELIXIR", "/home/jes/.asdf/installs/elixir/1.18.4-otp-27/bin/elixir"
)
ELIXIR_BIN = str(pathlib.Path(ELIXIR).parent)
NODE = "/usr/bin/node"
ERLANG_BIN = "/home/jes/.asdf/installs/erlang/27.3.4.8/bin"
TEST_SOURCE = PROVIDER_ROOT / "docs/measurements/log-inventory-http-1/log_inventory_http.exs"
SCRIPT_SOURCE = PROVIDER_ROOT / "docs/measurements/log-inventory-http-1/log_inventory_http_runner.exs"
RUNNER_SOURCE = pathlib.Path(__file__).resolve()
WRAPPER_SOURCE = PROVIDER_ROOT / "worker/test/real-log-inventory-socket-worker.mjs"
WRANGLER_SOURCE = PROVIDER_ROOT / "worker/wrangler.log-inventory-integration.jsonc"
CLIENT_LIB = CLIENT_ROOT / "commonplace_log/lib/commonplace/log"
CLIENT_TEST = CLIENT_ROOT / "commonplace_log/test/cloudflare_sidecar_log_inventory_test.exs"
COMPILE_SOURCES = [
    CLIENT_LIB / "jcs.ex",
    CLIENT_LIB / "entry.ex",
    CLIENT_LIB / "persistence.ex",
    CLIENT_LIB / "persistence/cloudflare_sidecar/transport.ex",
    CLIENT_LIB / "persistence/cloudflare_sidecar/httpc.ex",
    CLIENT_LIB / "persistence/cloudflare_sidecar.ex",
]
PROVIDER_INPUTS = [
    *sorted((PROVIDER_ROOT / "worker/src").rglob("*.ts")),
    PROVIDER_ROOT / "worker/package.json",
    PROVIDER_ROOT / "worker/package-lock.json",
    WRAPPER_SOURCE,
    WRANGLER_SOURCE,
    TEST_SOURCE,
    SCRIPT_SOURCE,
    RUNNER_SOURCE,
]
CLIENT_INPUTS = [*COMPILE_SOURCES, CLIENT_ROOT / "commonplace_log/mix.lock"]
for path in PROVIDER_INPUTS + CLIENT_INPUTS:
    if not path.is_file():
        raise SystemExit(f"missing runner input: {path}")
if not (WORKER_DEPS / "wrangler/bin/wrangler.js").is_file():
    raise SystemExit(f"missing cached worker dependencies: {WORKER_DEPS}")
if not pathlib.Path(ELIXIR).is_file():
    raise SystemExit(f"missing pinned Elixir: {ELIXIR}")


def git(root, *args):
    return subprocess.check_output(["git", *args], cwd=root, text=True).strip()


provider_head = git(PROVIDER_ROOT, "rev-parse", "HEAD")
provider_product = git(PROVIDER_ROOT, "rev-parse", EXPECTED_PROVIDER_PRODUCT)
if subprocess.run(
    ["git", "merge-base", "--is-ancestor", provider_product, provider_head], cwd=PROVIDER_ROOT
).returncode != 0:
    raise SystemExit("provider worktree is not based on the accepted provider product")
if subprocess.run(
    ["git", "diff", "--quiet", provider_product, provider_head, "--", "worker/src", "worker/package.json", "worker/package-lock.json"],
    cwd=PROVIDER_ROOT,
).returncode != 0:
    raise SystemExit("provider worker product differs from accepted 804c4d43 source")
client_head = git(CLIENT_ROOT, "rev-parse", "HEAD")
if subprocess.run(
    ["git", "merge-base", "--is-ancestor", CLIENT_COMMIT, client_head], cwd=CLIENT_ROOT
).returncode != 0:
    raise SystemExit(f"client HEAD {client_head} is not a descendant of accepted pin {CLIENT_COMMIT}")
status_lines = git(CLIENT_ROOT, "status", "--porcelain", "--untracked-files=all").splitlines()
for status_line in status_lines:
    status_path = status_line[3:] if len(status_line) >= 4 else ""
    evidence_name = pathlib.Path(status_path).name
    if status_path == "tmp" or status_path.startswith("tmp/"):
        continue
    if status_path.startswith("docs/measurements/") and evidence_name in {"RESULTS.md", "RESULTS.json"}:
        continue
    raise SystemExit(f"client worktree has non-evidence change: {status_line}")
provider_status = git(PROVIDER_ROOT, "status", "--porcelain", "--untracked-files=all").splitlines()
if [line for line in provider_status if not line.startswith("?? tmp/")]:
    raise SystemExit("provider worktree has non-measurement changes")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


expected_client_sidecar_sha = "7176c8e583d05296c3b831da2132248896934facacfa497a86e207fca78f4f6a"
client_sidecar = CLIENT_LIB / "persistence/cloudflare_sidecar.ex"
if sha256(client_sidecar) != expected_client_sidecar_sha:
    raise SystemExit("client sidecar source does not match accepted file pin")
for client_input in CLIENT_INPUTS:
    relative = client_input.relative_to(CLIENT_ROOT).as_posix()
    accepted_bytes = subprocess.check_output(
        ["git", "show", f"{CLIENT_COMMIT}:{relative}"], cwd=CLIENT_ROOT
    )
    if client_input.read_bytes() != accepted_bytes:
        raise SystemExit(f"client compile input differs from accepted pin: {relative}")


def discover_beams():
    return sorted(BEAM_ROOT.rglob("*.beam"))


def discover_runtime():
    return sorted(path for path in WORKER_DEPS.rglob("*") if path.is_file())


beams = discover_beams()
runtime_files = discover_runtime()
if len(beams) != 847:
    raise SystemExit(f"cached BEAM input count mismatch: {len(beams)} != 847")
if len(runtime_files) != 3221:
    raise SystemExit(f"worker runtime input count mismatch: {len(runtime_files)} != 3221")


def hashes(beam_files, runtime_inputs):
    return {
        "provider_source": {str(path.relative_to(PROVIDER_ROOT)): sha256(path) for path in PROVIDER_INPUTS},
        "client_source": {str(path.relative_to(CLIENT_ROOT)): sha256(path) for path in CLIENT_INPUTS},
        "cached_beams": {str(path): sha256(path) for path in beam_files},
        "worker_runtime": {str(path): sha256(path) for path in runtime_inputs},
    }


pre = hashes(beams, runtime_files)
(OUTPUT / "input-sha256.json").write_text(json.dumps(pre, indent=2, sort_keys=True) + "\n")
(OUTPUT / "source-pins.json").write_text(json.dumps({
    "provider_product_commit": provider_product,
    "provider_worktree_head": provider_head,
    "client_source_commit": CLIENT_COMMIT,
    "client_worktree_head": client_head,
    "client_source_root": str(CLIENT_ROOT),
    "provider_source_root": str(PROVIDER_ROOT),
    "beam_root": str(BEAM_ROOT),
    "cached_beam_count": len(beams),
    "worker_runtime_root": str(WORKER_DEPS),
    "worker_runtime_count": len(runtime_files),
    "compile_sources": [str(path) for path in COMPILE_SOURCES],
    "test_source": str(TEST_SOURCE),
    "wrapper_source": str(WRAPPER_SOURCE),
    "public_auth_claim": False,
}, indent=2, sort_keys=True) + "\n")

SOURCE = OUTPUT / "provider-source"
SOURCE.mkdir()
archive = subprocess.Popen(["git", "archive", "--format=tar", provider_head], cwd=PROVIDER_ROOT, stdout=subprocess.PIPE)
with tarfile.open(fileobj=archive.stdout, mode="r|") as stream:
    stream.extractall(SOURCE)
if archive.wait() != 0:
    raise SystemExit("provider source archive failed")
(SOURCE / "worker/node_modules").symlink_to(WORKER_DEPS)

beam_args = [part for ebin in sorted(BEAM_ROOT.glob("*/ebin")) for part in ("-pa", str(ebin))]
isolated_ebin = OUTPUT / "client-ebin"
isolated_ebin.mkdir()
elixirc = str(pathlib.Path(ELIXIR).with_name("elixirc"))
compile_cmd = [elixirc, *beam_args, "-o", str(isolated_ebin), *[str(path) for path in COMPILE_SOURCES]]
port_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
port_socket.bind(("127.0.0.1", 0))
port = port_socket.getsockname()[1]
port_socket.close()
wrangler_cmd = [
    NODE,
    str(SOURCE / "worker/node_modules/wrangler/bin/wrangler.js"),
    "dev", "--local", "--config", str(SOURCE / "worker/wrangler.log-inventory-integration.jsonc"),
    "--ip", "127.0.0.1", "--port", str(port), "--persist-to", str(OUTPUT / "state"),
]
test_cmd = [ELIXIR, *beam_args, "-pa", str(isolated_ebin), str(SOURCE / "docs/measurements/log-inventory-http-1/log_inventory_http_runner.exs")]
(OUTPUT / "command.json").write_text(json.dumps({
    "compile_argv": compile_cmd,
    "wrangler_argv": wrangler_cmd,
    "test_argv": test_cmd,
    "cwd": str(SOURCE),
    "base_url": f"http://127.0.0.1:{port}",
    "provider_product_commit": provider_product,
    "client_source_commit": CLIENT_COMMIT,
    "client_worktree_head": client_head,
    "compile_timeout_seconds": 120,
    "wrangler_start_timeout_seconds": 30,
    "test_timeout_seconds": 180,
    "term_grace_seconds": 5,
    "kill_grace_seconds": 2,
    "expected_exunit_total": 1,
}, indent=2) + "\n")

for private_dir in (OUTPUT / "home", OUTPUT / "config", OUTPUT / "tmp"):
    private_dir.mkdir(parents=True, exist_ok=True)
env = {
    "PATH": ELIXIR_BIN + os.pathsep + ERLANG_BIN + os.pathsep + "/usr/bin:/bin",
    "HOME": str(OUTPUT / "home"),
    "XDG_CONFIG_HOME": str(OUTPUT / "config"),
    "TMPDIR": str(OUTPUT / "tmp"),
    "ERL_FLAGS": "+S 2:2",
    "WRANGLER_SEND_METRICS": "false",
    "CI": "1",
    "NO_COLOR": "1",
    "LOG_INVENTORY_HTTP_TEST_FILE": str(SOURCE / "docs/measurements/log-inventory-http-1/log_inventory_http.exs"),
    "LOG_INVENTORY_HTTP_RESULT_FILE": str(OUTPUT / "test-result.json"),
    "LOG_INVENTORY_HTTP_BASE_URL": f"http://127.0.0.1:{port}",
}
owned = []
cleanup_in_progress = False
first_signal_received = False
signal_exit_code = None
finalizing = False
blocked_signals = {signal.SIGTERM, signal.SIGINT}


def group_exists(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def stop_record(record):
    process = record["process"]
    pgid = record["pgid"]
    if group_exists(pgid):
        try:
            os.killpg(pgid, signal.SIGTERM)
            record["term_sent"] = True
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 5
        while group_exists(pgid) and time.monotonic() < deadline:
            process.poll()
            time.sleep(0.05)
        if group_exists(pgid):
            try:
                os.killpg(pgid, signal.SIGKILL)
                record["kill_sent"] = True
            except ProcessLookupError:
                pass
            deadline = time.monotonic() + 2
            while group_exists(pgid) and time.monotonic() < deadline:
                process.poll()
                time.sleep(0.05)
    record["leader_exit"] = process.poll()
    record["group_absent"] = not group_exists(pgid)
    record["forced_cleanup_hold"] = record["kill_sent"] or not record["group_absent"]


def cleanup_all():
    global cleanup_in_progress
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, blocked_signals)
    try:
        if cleanup_in_progress:
            return
        cleanup_in_progress = True
        for record in reversed(owned):
            try:
                stop_record(record)
            except BaseException as error:
                record["cleanup_error"] = repr(error)
                record["forced_cleanup_hold"] = True
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def on_signal(signum, _frame):
    global first_signal_received, signal_exit_code
    first_signal_received = True
    signal_exit_code = 128 + signum
    if finalizing:
        return
    cleanup_all()
    raise SystemExit(signal_exit_code)


signal.signal(signal.SIGTERM, on_signal)
signal.signal(signal.SIGINT, on_signal)


def spawn_owned(argv, cwd, child_env, stdout, stderr, label):
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, blocked_signals)
    process = None
    try:
        process = subprocess.Popen(
            argv, cwd=cwd, env=child_env, stdout=stdout, stderr=stderr,
            start_new_session=True,
            preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask),
        )
        record = {
            "label": label,
            "pid": process.pid,
            "pgid": process.pid,
            "term_sent": False,
            "kill_sent": False,
            "process": process,
        }
        owned.append(record)
        return record
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def run_group(argv, cwd, timeout_seconds, stdout_path, stderr_path, label, child_env):
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        record = spawn_owned(argv, cwd, child_env, stdout, stderr, label)
        process = record["process"]
        timed_out = False
        try:
            process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            stop_record(record)
        return process.poll(), timed_out, record


compile_rc = None
compile_timeout = False
wrangler_rc = None
wrangler_timeout = False
test_rc = None
test_timeout = False
compile_record = None
wrangler_record = None
test_record = None
wrangler_handles = []
spawn_error = None
wait_error = None
try:
    try:
        compile_rc, compile_timeout, compile_record = run_group(
            compile_cmd, PROVIDER_ROOT, 120, OUTPUT / "compile-stdout", OUTPUT / "compile-stderr", "elixirc", env
        )
        if compile_rc == 0:
            wrangler_handles = [(OUTPUT / "wrangler-stdout").open("wb"), (OUTPUT / "wrangler-stderr").open("wb")]
            wrangler_record = spawn_owned(
                wrangler_cmd, SOURCE / "worker", {**env, "WRANGLER_LOG_PATH": str(OUTPUT / "wrangler.log")},
                wrangler_handles[0], wrangler_handles[1], "wrangler",
            )
            wrangler_process = wrangler_record["process"]
            ready_deadline = time.monotonic() + 30
            while time.monotonic() < ready_deadline:
                if wrangler_process.poll() is not None:
                    break
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                        break
                except OSError:
                    time.sleep(0.1)
            else:
                wrangler_timeout = True
            if wrangler_process.poll() is None and not wrangler_timeout:
                test_rc, test_timeout, test_record = run_group(
                    test_cmd, SOURCE, 180, OUTPUT / "stdout", OUTPUT / "stderr", "elixir-test", env
                )
            wrangler_rc = wrangler_process.poll()
    except BaseException as error:
        spawn_error = repr(error)
finally:
    finalizing = True
    cleanup_all()
    if wrangler_record is not None:
        wrangler_rc = wrangler_record["process"].poll()
    for handle in wrangler_handles:
        handle.close()
    for stream in (OUTPUT / "compile-stdout", OUTPUT / "compile-stderr", OUTPUT / "stdout", OUTPUT / "stderr", OUTPUT / "wrangler-stdout", OUTPUT / "wrangler-stderr"):
        stream.touch(exist_ok=True)
    post_beams = discover_beams()
    post_runtime = discover_runtime()
    post = hashes(post_beams, post_runtime)
    (OUTPUT / "post-sha256.json").write_text(json.dumps(post, indent=2, sort_keys=True) + "\n")
    equal = pre == post
    (OUTPUT / "input-equality.json").write_text(json.dumps({"equal": equal}) + "\n")
    (OUTPUT / "runtime-membership.json").write_text(json.dumps({
        "pre": [str(path) for path in runtime_files],
        "post": [str(path) for path in post_runtime],
        "added": [str(path) for path in sorted(set(post_runtime) - set(runtime_files))],
        "removed": [str(path) for path in sorted(set(runtime_files) - set(post_runtime))],
    }, indent=2) + "\n")
    result = None
    result_path = OUTPUT / "test-result.json"
    if result_path.is_file():
        try:
            result = json.loads(result_path.read_text())
        except (OSError, ValueError):
            pass
    test_ok = isinstance(result, dict) and result.get("total") == 1 and result.get("failures") == 0 and \
        result.get("excluded") == 0 and result.get("skipped") == 0
    cleanup_hold = any(record.get("forced_cleanup_hold") for record in owned)
    native_rc = compile_rc if compile_rc not in (None, 0) else (test_rc if test_rc is not None else 125)
    verdict = native_rc if signal_exit_code is None and spawn_error is None and wait_error is None and \
        equal and not compile_timeout and not wrangler_timeout and not test_timeout and not cleanup_hold and \
        compile_rc == 0 and test_rc == 0 and test_ok else 125
    (OUTPUT / "native.rc").write_text(json.dumps({
        "compile_rc": compile_rc,
        "wrangler_rc": wrangler_rc,
        "test_rc": test_rc,
        "native_rc": native_rc,
        "compile_timeout": compile_timeout,
        "wrangler_timeout": wrangler_timeout,
        "test_timeout": test_timeout,
        "test_result_ok": test_ok,
        "forced_cleanup_hold": cleanup_hold,
        "spawn_error": spawn_error,
        "wait_error": wait_error,
        "signal_exit_code": signal_exit_code,
    }, indent=2) + "\n")
    (OUTPUT / "verdict.rc").write_text(str(verdict) + "\n")
    for record in owned:
        record.pop("process", None)
    (OUTPUT / "process-groups.json").write_text(json.dumps({
        "groups": owned,
        "first_signal_received": first_signal_received,
        "term_grace_seconds": 5,
        "kill_grace_seconds": 2,
        "cleanup_in_finally": True,
    }, indent=2, sort_keys=True) + "\n")
raise SystemExit(verdict)
