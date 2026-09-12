import hashlib
import json
import os
import pathlib
import signal
import socket
import subprocess
import sys
import time


root = pathlib.Path(__file__).resolve().parents[3]
worker_dir = root / "worker"
client_lib = root / "commonplace_log/lib/commonplace/log"
output = pathlib.Path(sys.argv[1]).resolve()
if output.exists():
    raise SystemExit(f"refusing existing output: {output}")
output.mkdir(parents=True)

provider_deps = pathlib.Path("/home/jes/commonplace-log/worker/node_modules")
beam_root = pathlib.Path(os.environ.get(
    "RESTORE_HTTP_BEAM_ROOT",
    "/home/jes/codex-save-state-1/tmp/origin-receipt-1/_build/test/lib",
))
elixir = os.environ.get(
    "RESTORE_HTTP_ELIXIR",
    "/home/jes/.asdf/installs/elixir/1.18.4-otp-27/bin/elixir",
)
node = os.environ.get("RESTORE_HTTP_NODE", "node")
client_source_commit = "4fa621db5d257260118fbf649049402ff09b5ef6"
wire_product_commit = "6194033"
wire_fixture_base_commit = "5245b1b"
expected_client_sidecar_sha256 = (
    "2022de840fd71355f36b23116c60934918773a5dfd8363dc39e48b06fe1199ab"
)
client_sidecar = client_lib / "persistence/cloudflare_sidecar.ex"
test_file = root / "commonplace_log/test/restore_http_integration_test.exs"
script_file = root / "docs/measurements/restore-http-native-1/restore_http.exs"
runner_file = pathlib.Path(__file__).resolve()
provenance_file = root / "docs/measurements/restore-http-native-1/client-sidecar-provenance.json"
compile_sources = [
    client_lib / "jcs.ex",
    client_lib / "entry.ex",
    client_lib / "persistence.ex",
    client_lib / "persistence/cloudflare_sidecar/transport.ex",
    client_lib / "persistence/cloudflare_sidecar/httpc.ex",
    client_sidecar,
]
worker_inputs = [
    *sorted((worker_dir / "src").rglob("*.ts")),
    worker_dir / "test/real-restore-socket-worker.mjs",
    worker_dir / "wrangler.restore-integration.jsonc",
    worker_dir / "package.json",
    worker_dir / "package-lock.json",
]
for path in compile_sources + [test_file, script_file, runner_file, provenance_file, *worker_inputs]:
    if not path.is_file():
        raise SystemExit(f"missing runner input: {path}")
cached_beams = sorted(beam_root.rglob("*.beam"))
if not cached_beams:
    raise SystemExit(f"no cached BEAM inputs under {beam_root}")
if not (provider_deps / ".bin/wrangler").exists():
    raise SystemExit(f"missing pinned worker dependencies: {provider_deps}")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


actual_head = subprocess.check_output(
    ["git", "rev-parse", "HEAD"], cwd=root, text=True
).strip()
if sha256(client_sidecar) != expected_client_sidecar_sha256:
    raise SystemExit("client sidecar provenance checksum mismatch")
runtime_files = sorted(path for path in provider_deps.rglob("*") if path.is_file())
if not runtime_files:
    raise SystemExit(f"no worker runtime files under {provider_deps}")


def hashes():
    return {
        "elixir_source": {
            str(path.relative_to(root)): sha256(path)
            for path in compile_sources + [test_file, script_file, runner_file, provenance_file]
        },
        "worker_source": {str(path.relative_to(root)): sha256(path) for path in worker_inputs},
        "worker_runtime": {str(path): sha256(path) for path in runtime_files},
        "cached_beams": {str(path): sha256(path) for path in cached_beams},
    }


pre = hashes()
(output / "input-sha256.json").write_text(json.dumps(pre, indent=2, sort_keys=True) + "\n")
(output / "source-pins.json").write_text(json.dumps({
    "runner_worktree_head": actual_head,
    "client_source_commit": client_source_commit,
    "wire_product_commit": wire_product_commit,
    "wire_fixture_base_commit": wire_fixture_base_commit,
    "worker_worktree": str(root),
    "beam_root": str(beam_root),
    "cached_beam_count": len(cached_beams),
    "worker_runtime_root": str(provider_deps),
    "worker_runtime_file_count": len(runtime_files),
    "client_sidecar": str(client_sidecar),
    "client_sidecar_expected_sha256": expected_client_sidecar_sha256,
    "client_sidecar_provenance": str(provenance_file),
    "compile_sources": [str(path) for path in compile_sources],
    "test_file": str(test_file),
}, indent=2, sort_keys=True) + "\n")

beam_args = [part for ebin in sorted(beam_root.glob("*/ebin")) for part in ("-pa", str(ebin))]
client_ebin = output / "client-ebin"
client_ebin.mkdir()
elixirc = str(pathlib.Path(elixir).with_name("elixirc"))
compile_cmd = [elixirc, *beam_args, "-o", str(client_ebin), *[str(path) for path in compile_sources]]

port_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
port_socket.bind(("127.0.0.1", 0))
port = port_socket.getsockname()[1]
port_socket.close()
wrangler = provider_deps / "wrangler/bin/wrangler.js"
wrangler_cmd = [
    node, str(wrangler), "dev", "--local", "--config", str(worker_dir / "wrangler.restore-integration.jsonc"),
    "--ip", "127.0.0.1", "--port", str(port), "--persist-to", str(output / "state"),
]
test_cmd = [elixir, *beam_args, "-pa", str(client_ebin), str(script_file)]
(output / "command.json").write_text(json.dumps({
    "runner_worktree_head": actual_head,
    "compile_argv": compile_cmd,
    "wrangler_argv": wrangler_cmd,
    "test_argv": test_cmd,
    "cwd": str(root),
    "base_url": f"http://127.0.0.1:{port}",
    "compile_timeout_seconds": 120,
    "wrangler_start_timeout_seconds": 30,
    "test_timeout_seconds": 180,
    "term_grace_seconds": 5,
    "kill_grace_seconds": 2,
    "worker_target": "elixir-real-socket-integration",
}, indent=2) + "\n")

for private_dir in (output / "home", output / "config", output / "tmp"):
    private_dir.mkdir(parents=True, exist_ok=True)
env = {
    "PATH": os.environ.get("PATH", ""),
    "HOME": str(output / "home"),
    "XDG_CONFIG_HOME": str(output / "config"),
    "TMPDIR": str(output / "tmp"),
    "ERL_FLAGS": "+S 2:2",
    "WRANGLER_SEND_METRICS": "false",
    "CI": "1",
    "NO_COLOR": "1",
}
env["RESTORE_HTTP_TEST_FILE"] = str(test_file)
env["RESTORE_HTTP_BASE_URL"] = f"http://127.0.0.1:{port}"
env["RESTORE_HTTP_RESULT_FILE"] = str(output / "test-result.json")

owned_groups = []
cleanup_in_progress = False


def group_exists(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def register_group(label, process):
    record = {
        "label": label,
        "pid": process.pid,
        "pgid": os.getpgid(process.pid),
        "term_sent": False,
        "kill_sent": False,
        "leader_exit": None,
        "group_absent": False,
        "forced_cleanup_hold": False,
        "process": process,
    }
    owned_groups.append(record)
    return record


def stop_record(record):
    process = record["process"]
    pgid = record["pgid"]
    if not group_exists(pgid):
        record["leader_exit"] = process.poll()
        record["group_absent"] = True
        return
    try:
        os.killpg(pgid, signal.SIGTERM)
        record["term_sent"] = True
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + 5
    while group_exists(pgid) and time.monotonic() < deadline:
        time.sleep(0.05)
    if group_exists(pgid):
        try:
            os.killpg(pgid, signal.SIGKILL)
            record["kill_sent"] = True
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 2
        while group_exists(pgid) and time.monotonic() < deadline:
            time.sleep(0.05)
    record["leader_exit"] = process.poll()
    record["group_absent"] = not group_exists(pgid)
    record["forced_cleanup_hold"] = not record["group_absent"]


def cleanup_all():
    global cleanup_in_progress
    if cleanup_in_progress:
        return
    cleanup_in_progress = True
    for record in reversed(owned_groups):
        try:
            stop_record(record)
        except BaseException as error:
            record["cleanup_error"] = repr(error)
            record["forced_cleanup_hold"] = True


def on_signal(signum, _frame):
    cleanup_all()
    raise SystemExit(128 + signum)


signal.signal(signal.SIGTERM, on_signal)
signal.signal(signal.SIGINT, on_signal)


def run_group(argv, cwd, timeout_seconds, stdout_path, stderr_path, label):
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        process = subprocess.Popen(
            argv, cwd=cwd, env=env, stdout=stdout, stderr=stderr,
            start_new_session=True,
        )
        record = register_group(label, process)
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
worker_node_modules = worker_dir / "node_modules"
symlink_created = False
wrangler_handles = []
wrangler_record = None
try:
    compile_rc, compile_timeout, _compile_record = run_group(
        compile_cmd, root, 120, output / "compile-stdout", output / "compile-stderr", "elixirc"
    )
    if compile_rc == 0:
        (output / "node_modules-link.pending").write_text(str(provider_deps) + "\n")
        if worker_node_modules.exists() or worker_node_modules.is_symlink():
            raise SystemExit("worker node_modules path is occupied")
        worker_node_modules.symlink_to(provider_deps)
        symlink_created = True
        worker_env = {**env, "WRANGLER_LOG_PATH": str(output / "wrangler.log")}
        wrangler_handles = [
            (output / "wrangler-stdout").open("wb"),
            (output / "wrangler-stderr").open("wb"),
        ]
        try:
            wrangler_process = subprocess.Popen(
                wrangler_cmd, cwd=worker_dir, env=worker_env,
                stdout=wrangler_handles[0], stderr=wrangler_handles[1],
                start_new_session=True,
            )
            wrangler_record = register_group("wrangler", wrangler_process)
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
                test_rc, test_timeout, _test_record = run_group(
                    test_cmd, root, 180, output / "stdout", output / "stderr", "elixir-test"
                )
            wrangler_rc = wrangler_process.poll()
        finally:
            if wrangler_record is not None:
                stop_record(wrangler_record)
                wrangler_rc = wrangler_process.poll()
            for handle in wrangler_handles:
                handle.close()
            wrangler_handles = []
    else:
        (output / "stdout").write_text("")
        (output / "stderr").write_text("")
finally:
    cleanup_all()
    if symlink_created and worker_node_modules.is_symlink() and worker_node_modules.resolve() == provider_deps.resolve():
        worker_node_modules.unlink()
    for handle in wrangler_handles:
        handle.close()
    for stream in (output / "stdout", output / "stderr", output / "wrangler-stdout", output / "wrangler-stderr"):
        stream.touch(exist_ok=True)
    for record in owned_groups:
        record.pop("process", None)
    post = hashes()
    (output / "post-sha256.json").write_text(json.dumps(post, indent=2, sort_keys=True) + "\n")
    equal = pre == post
    (output / "input-equality.json").write_text(json.dumps({"equal": equal}) + "\n")
    test_result = None
    result_file = output / "test-result.json"
    if result_file.is_file():
        try:
            test_result = json.loads(result_file.read_text())
        except (OSError, ValueError):
            test_result = None
    test_result_ok = bool(
        isinstance(test_result, dict)
        and test_result.get("total") == 1
        and test_result.get("failures") == 0
        and test_result.get("skipped") == 0
        and test_result.get("excluded") == 0
    )
    cleanup_hold = any(record.get("forced_cleanup_hold") for record in owned_groups)
    native_rc = test_rc if compile_rc == 0 and test_rc is not None else (compile_rc or 125)
    verdict = native_rc if (
        equal and not compile_timeout and not test_timeout and not wrangler_timeout
        and not cleanup_hold and compile_rc == 0 and test_rc == 0 and test_result_ok
    ) else 125
    (output / "native.rc").write_text(json.dumps({
        "compile_rc": compile_rc,
        "wrangler_rc": wrangler_rc,
        "test_rc": test_rc,
        "native_rc": native_rc,
        "compile_timeout": compile_timeout,
        "wrangler_timeout": wrangler_timeout,
        "test_timeout": test_timeout,
        "test_result_ok": test_result_ok,
        "forced_cleanup_hold": cleanup_hold,
    }, indent=2) + "\n")
    (output / "verdict.rc").write_text(str(verdict) + "\n")
    (output / "process-groups.json").write_text(json.dumps({
        "groups": owned_groups,
        "term_grace_seconds": 5,
        "kill_grace_seconds": 2,
        "cleanup_in_finally": True,
    }, indent=2, sort_keys=True) + "\n")

raise SystemExit(verdict)
