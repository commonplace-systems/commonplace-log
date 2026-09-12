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


def hashes():
    return {
        "elixir_source": {
            str(path.relative_to(root)): sha256(path)
            for path in compile_sources + [test_file, script_file, runner_file, provenance_file]
        },
        "worker_source": {str(path.relative_to(root)): sha256(path) for path in worker_inputs},
        "cached_beams": {str(path): sha256(path) for path in cached_beams},
    }


pre = hashes()
(output / "input-sha256.json").write_text(json.dumps(pre, indent=2, sort_keys=True) + "\n")
(output / "source-pins.json").write_text(json.dumps({
    "client_source_commit": client_source_commit,
    "wire_product_commit": wire_product_commit,
    "wire_fixture_base_commit": wire_fixture_base_commit,
    "worker_worktree": str(root),
    "beam_root": str(beam_root),
    "cached_beam_count": len(cached_beams),
    "client_sidecar": str(client_sidecar),
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
    "compile_argv": compile_cmd,
    "wrangler_argv": wrangler_cmd,
    "test_argv": test_cmd,
    "cwd": str(root),
    "base_url": f"http://127.0.0.1:{port}",
    "compile_timeout_seconds": 120,
    "wrangler_start_timeout_seconds": 30,
    "test_timeout_seconds": 180,
    "term_grace_seconds": 5,
    "worker_target": "elixir-real-socket-integration",
}, indent=2) + "\n")

env = {
    "PATH": os.environ.get("PATH", ""),
    "HOME": str(output / "home"),
    "XDG_CONFIG_HOME": str(output / "config"),
    "WRANGLER_SEND_METRICS": "false",
    "CI": "1",
    "NO_COLOR": "1",
}
env["RESTORE_HTTP_TEST_FILE"] = str(test_file)
env["RESTORE_HTTP_BASE_URL"] = f"http://127.0.0.1:{port}"
env["RESTORE_HTTP_RESULT_FILE"] = str(output / "test-result.json")


def text(value):
    if value is None:
        return ""
    return value.decode(errors="replace") if isinstance(value, bytes) else value


def run_group(argv, cwd, timeout_seconds, stdout_path, stderr_path):
    process = subprocess.Popen(
        argv, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True, text=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout_seconds)
        stdout, stderr = text(stdout), text(stderr)
        stdout_path.write_text(stdout)
        stderr_path.write_text(stderr)
        return process.returncode, False
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
        stdout_path.write_text(text(stdout))
        stderr_path.write_text(text(stderr))
        return process.returncode, True


def stop_group(process):
    if process is None or process.poll() is not None:
        return None if process is None else process.returncode
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
    return process.returncode


compile_rc = None
compile_timeout = False
wrangler_rc = None
wrangler_timeout = False
test_rc = None
test_timeout = False
test_process = None
wrangler_process = None
try:
    compile_rc, compile_timeout = run_group(
        compile_cmd, root, 120, output / "compile-stdout", output / "compile-stderr"
    )
    if compile_rc == 0:
        (output / "node_modules-link.pending").write_text(str(provider_deps) + "\n")
        worker_node_modules = worker_dir / "node_modules"
        if worker_node_modules.exists() or worker_node_modules.is_symlink():
            raise SystemExit("worker node_modules path is occupied")
        worker_node_modules.symlink_to(provider_deps)
        try:
            worker_env = {**env, "WRANGLER_LOG_PATH": str(output / "wrangler.log")}
            wrangler_process = subprocess.Popen(
                wrangler_cmd, cwd=worker_dir, env=worker_env,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                start_new_session=True, text=True,
            )
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
                test_rc, test_timeout = run_group(
                    test_cmd, root, 180, output / "stdout", output / "stderr"
                )
            else:
                wrangler_rc = wrangler_process.poll()
        finally:
            if wrangler_process is not None:
                try:
                    wrangler_out, wrangler_err = wrangler_process.communicate(timeout=0)
                except subprocess.TimeoutExpired:
                    wrangler_out = wrangler_err = ""
                if wrangler_process.poll() is None:
                    stop_group(wrangler_process)
                    wrangler_out, wrangler_err = wrangler_process.communicate()
                wrangler_rc = wrangler_process.returncode
                (output / "wrangler-stdout").write_text(text(wrangler_out))
                (output / "wrangler-stderr").write_text(text(wrangler_err))
            if worker_node_modules.is_symlink() and worker_node_modules.resolve() == provider_deps.resolve():
                worker_node_modules.unlink()
    else:
        (output / "stdout").write_text("")
        (output / "stderr").write_text("")
finally:
    if test_process is not None:
        stop_group(test_process)
    if wrangler_process is not None:
        stop_group(wrangler_process)
    for stream in (output / "stdout", output / "stderr", output / "wrangler-stdout", output / "wrangler-stderr"):
        stream.touch(exist_ok=True)
    post = hashes()
    (output / "post-sha256.json").write_text(json.dumps(post, indent=2, sort_keys=True) + "\n")
    equal = pre == post
    (output / "input-equality.json").write_text(json.dumps({"equal": equal}) + "\n")
    native_rc = test_rc if compile_rc == 0 and test_rc is not None else (compile_rc or 125)
    verdict = native_rc if equal and not compile_timeout and not test_timeout and not wrangler_timeout else 125
    (output / "native.rc").write_text(json.dumps({
        "compile_rc": compile_rc,
        "wrangler_rc": wrangler_rc,
        "test_rc": test_rc,
        "native_rc": native_rc,
        "compile_timeout": compile_timeout,
        "wrangler_timeout": wrangler_timeout,
        "test_timeout": test_timeout,
    }, indent=2) + "\n")
    (output / "verdict.rc").write_text(str(verdict) + "\n")
    (output / "process-groups.json").write_text(json.dumps({
        "wrangler_group_owned": True,
        "test_group_owned": True,
        "term_grace_seconds": 5,
        "cleanup_in_finally": True,
    }, indent=2) + "\n")

raise SystemExit(verdict)
