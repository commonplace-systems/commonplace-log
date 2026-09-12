import hashlib
import json
import os
import pathlib
import signal
import subprocess
import sys

repo = pathlib.Path(__file__).resolve().parents[3]
out = pathlib.Path(sys.argv[1]).resolve()
if out.exists():
    raise SystemExit(f"refusing existing output: {out}")
out.mkdir(parents=True)

beam_root = pathlib.Path(os.environ.get(
    "RESTORE_CLIENT_BEAM_ROOT",
    "/home/jes/codex-save-state-1/tmp/origin-receipt-1/_build/test/lib",
))
elixir = os.environ.get(
    "RESTORE_CLIENT_ELIXIR",
    "/home/jes/.asdf/installs/elixir/1.18.4-otp-27/bin/elixir",
)
source_commit = subprocess.check_output(
    ["git", "rev-parse", "HEAD"], cwd=repo, text=True
).strip()
base_commit = subprocess.check_output(
    ["git", "rev-parse", "bc1ec30^{commit}"], cwd=repo, text=True
).strip()
if subprocess.run(
    ["git", "merge-base", "--is-ancestor", base_commit, source_commit], cwd=repo
).returncode:
    raise SystemExit("source is not based on pinned restore-binding commit bc1ec30")

source_file = repo / "commonplace_log/lib/commonplace/log/persistence/cloudflare_sidecar.ex"
test_file = repo / "commonplace_log/test/restore_bundle_client_test.exs"
script_file = pathlib.Path(__file__).resolve().with_name("restore_client.exs")
tracked = [source_file, test_file, script_file, pathlib.Path(__file__), repo / "commonplace_log/mix.lock"]

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def hashes():
    return {str(path.relative_to(repo)): sha256(path) for path in tracked}

pre = hashes()
(out / "input-sha256.json").write_text(json.dumps(pre, indent=2, sort_keys=True) + "\n")
(out / "source-pins.json").write_text(json.dumps({
    "source_commit": source_commit,
    "base_commit": base_commit,
    "source_file": str(source_file),
    "test_file": str(test_file),
    "beam_root": str(beam_root),
}, indent=2, sort_keys=True) + "\n")

beam_args = [part for ebin in sorted(beam_root.glob("*/ebin")) for part in ("-pa", str(ebin))]
isolated = out / "isolated-ebin"
isolated.mkdir()
elixirc = str(pathlib.Path(elixir).with_name("elixirc"))
compile_cmd = [elixirc, *beam_args, "-o", str(isolated), str(source_file)]
test_cmd = [elixir, *beam_args, "-pa", str(isolated), str(script_file)]
(out / "command.json").write_text(json.dumps({
    "compile_argv": compile_cmd,
    "test_argv": test_cmd,
    "cwd": str(repo),
    "source_commit": source_commit,
    "base_commit": base_commit,
    "test_file": str(test_file),
}, indent=2) + "\n")

env = os.environ.copy()
env["RESTORE_CLIENT_TEST_FILE"] = str(test_file)
proc = None
compile_stdout = compile_stderr = ""
try:
    compiled = subprocess.run(
        compile_cmd, cwd=repo, env=env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60,
    )
    compile_stdout, compile_stderr = compiled.stdout or "", compiled.stderr or ""
    (out / "compile-stdout").write_text(compile_stdout)
    (out / "compile-stderr").write_text(compile_stderr)
    if compiled.returncode != 0:
        (out / "native-exit.json").write_text(json.dumps({
            "native_exit": compiled.returncode, "compile_failed": True, "timed_out": False,
        }) + "\n")
        raise SystemExit(compiled.returncode)

    proc = subprocess.Popen(
        test_cmd, cwd=repo, env=env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
    )
    stdout, stderr = proc.communicate(timeout=90)
except subprocess.TimeoutExpired as error:
    if proc is not None:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            stdout, stderr = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            stdout, stderr = proc.communicate()
    else:
        stdout, stderr = "", str(error)
    (out / "stdout").write_text(stdout or "")
    (out / "stderr").write_text(stderr or "")
    (out / "native-exit.json").write_text(json.dumps({
        "native_exit": None, "compile_failed": False, "timed_out": True, "timeout_exit": 124,
    }) + "\n")
    raise SystemExit(124)

(out / "stdout").write_text(stdout or "")
(out / "stderr").write_text(stderr or "")
(out / "native-exit.json").write_text(json.dumps({
    "native_exit": proc.returncode, "compile_failed": False, "timed_out": False,
}) + "\n")
post = hashes()
(out / "input-sha256-post.json").write_text(json.dumps(post, indent=2, sort_keys=True) + "\n")
(out / "input-equality.json").write_text(json.dumps({"equal": post == pre}, indent=2) + "\n")
if post != pre:
    raise SystemExit("input files changed during run")
print(stdout or "")
print(stderr or "", file=sys.stderr)
raise SystemExit(proc.returncode)
