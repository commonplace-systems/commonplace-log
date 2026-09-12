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
runner_file = pathlib.Path(__file__).resolve()
source_files = sorted((repo / "commonplace_log/lib").rglob("*.ex"))
compile_sources = [
    repo / "commonplace_log/lib/commonplace/log/jcs.ex",
    repo / "commonplace_log/lib/commonplace/log/entry.ex",
    repo / "commonplace_log/lib/commonplace/log/persistence.ex",
    repo / "commonplace_log/lib/commonplace/log/persistence/cloudflare_sidecar/transport.ex",
    repo / "commonplace_log/lib/commonplace/log/persistence/cloudflare_sidecar/httpc.ex",
    source_file,
]
for path in compile_sources + [test_file, script_file, runner_file, repo / "commonplace_log/mix.lock"]:
    if not path.is_file():
        raise SystemExit(f"missing runner input: {path}")

cached_beams = sorted(beam_root.rglob("*.beam"))
if not cached_beams:
    raise SystemExit(f"no cached BEAM inputs under {beam_root}")


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
            for path in source_files + [test_file, script_file, runner_file, repo / "commonplace_log/mix.lock"]
        },
        "cached_beams": {str(path): sha256(path) for path in cached_beams},
    }


pre = hashes()
(out / "input-sha256.json").write_text(json.dumps(pre, indent=2, sort_keys=True) + "\n")
(out / "source-pins.json").write_text(json.dumps({
    "source_commit": source_commit,
    "base_commit": base_commit,
    "source_file": str(source_file),
    "test_file": str(test_file),
    "compile_sources": [str(path) for path in compile_sources],
    "beam_root": str(beam_root),
    "cached_beam_count": len(cached_beams),
}, indent=2, sort_keys=True) + "\n")

beam_args = [part for ebin in sorted(beam_root.glob("*/ebin")) for part in ("-pa", str(ebin))]
isolated = out / "isolated-ebin"
isolated.mkdir()
elixirc = str(pathlib.Path(elixir).with_name("elixirc"))
compile_cmd = [elixirc, *beam_args, "-o", str(isolated), *[str(path) for path in compile_sources]]
test_cmd = [elixir, *beam_args, "-pa", str(isolated), str(script_file)]
(out / "command.json").write_text(json.dumps({
    "compile_argv": compile_cmd,
    "test_argv": test_cmd,
    "cwd": str(repo),
    "source_commit": source_commit,
    "base_commit": base_commit,
    "test_file": str(test_file),
    "compile_timeout_seconds": 120,
    "test_timeout_seconds": 180,
    "term_grace_seconds": 5,
}, indent=2) + "\n")


def run_group(argv, timeout_seconds):
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
        stdout, stderr = process.communicate(timeout=timeout_seconds)
        return process.returncode, stdout or "", stderr or "", False
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout or ""
        stderr = error.stderr or ""
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            tail_out, tail_err = process.communicate(timeout=5)
            stdout += tail_out or ""
            stderr += tail_err or ""
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            tail_out, tail_err = process.communicate()
            stdout += tail_out or ""
            stderr += tail_err or ""
        return 124, stdout, stderr, True


compile_rc = test_rc = None
compile_timed_out = test_timed_out = False
compile_stdout = compile_stderr = test_stdout = test_stderr = ""
native_rc = 125
try:
    compile_rc, compile_stdout, compile_stderr, compile_timed_out = run_group(compile_cmd, 120)
    (out / "compile-stdout").write_text(compile_stdout)
    (out / "compile-stderr").write_text(compile_stderr)
    if compile_rc == 0:
        test_rc, test_stdout, test_stderr, test_timed_out = run_group(test_cmd, 180)
        native_rc = test_rc
    else:
        native_rc = compile_rc
finally:
    (out / "stdout").write_text(test_stdout)
    (out / "stderr").write_text(test_stderr)
    post = hashes()
    (out / "input-sha256-post.json").write_text(json.dumps(post, indent=2, sort_keys=True) + "\n")
    equal = post == pre
    (out / "input-equality.json").write_text(json.dumps({"equal": equal}, indent=2) + "\n")
    native = {
        "native_exit": native_rc,
        "compile_exit": compile_rc,
        "test_exit": test_rc,
        "compile_failed": compile_rc not in (None, 0),
        "compile_timed_out": compile_timed_out,
        "test_timed_out": test_timed_out,
    }
    (out / "native-exit.json").write_text(json.dumps(native) + "\n")
    verdict = native_rc if equal else 125
    (out / "verdict.json").write_text(json.dumps({"native_exit": native_rc, "verdict_exit": verdict}) + "\n")

if compile_rc != 0:
    print(compile_stdout)
    print(compile_stderr, file=sys.stderr)
else:
    print(test_stdout)
    print(test_stderr, file=sys.stderr)
raise SystemExit(native_rc if pre == hashes() else 125)
