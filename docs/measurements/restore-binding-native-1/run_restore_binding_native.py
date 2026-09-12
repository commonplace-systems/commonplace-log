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

beam_root = pathlib.Path(
    os.environ.get(
        "RESTORE_BINDING_BEAM_ROOT",
        "/home/jes/codex-save-state-1/tmp/origin-receipt-1/_build/test/lib",
    )
)
source_commit = "6c24cbe"
actual_commit = subprocess.check_output(
    ["git", "rev-parse", "HEAD"], cwd=repo, text=True
).strip()
if actual_commit != source_commit:
    raise SystemExit(f"runner must execute pinned source {source_commit}, got {actual_commit}")

test_cases = [
    "test existing DocumentProfile lane keeps one writer across restart",
    "test restore preserves bytes and writer, then supports append and restart",
    "test pending marker fences ordinary owner calls and resumes without a writer sidecar",
    "test restore owner fences pending append, merge, and lease calls",
    "test existing unmarked log is refused without adding restore schema",
]

source_root = repo / "commonplace_log"
tracked_inputs = [
    repo / "docs/measurements/restore-binding-native-1/restore_binding_native.exs",
    pathlib.Path(__file__),
    source_root / "mix.exs",
    source_root / "mix.lock",
]
tracked_inputs.extend(sorted((source_root / "lib").rglob("*.ex")))

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

input_hashes = {str(path.relative_to(repo)): sha256(path) for path in tracked_inputs}
(out / "input-sha256.json").write_text(json.dumps(input_hashes, indent=2, sort_keys=True) + "\n")
(out / "source-pins.json").write_text(
    json.dumps(
        {
            "source_commit": source_commit,
            "source_root": str(source_root),
            "beam_root": str(beam_root),
            "input_sha256": input_hashes,
        },
        indent=2,
        sort_keys=True,
    )
    + "\n"
)

beam_args = [part for ebin in sorted(beam_root.glob("*/ebin")) for part in ("-pa", str(ebin))]
script = repo / "docs/measurements/restore-binding-native-1/restore_binding_native.exs"
cmd = [
    "/home/jes/.asdf/installs/elixir/1.18.4-otp-27/bin/elixir",
    *beam_args,
    str(script),
    str(out),
]
(out / "command.json").write_text(
    json.dumps({"argv": cmd, "cwd": str(repo), "source_commit": source_commit}, indent=2) + "\n"
)
env = os.environ.copy()
env.update(
    {
        "RESTORE_BINDING_BEAM_ROOT": str(beam_root),
        "RESTORE_BINDING_EXPECTED_CASES": "\n".join(test_cases),
    }
)

proc = None
try:
    proc = subprocess.Popen(
        cmd,
        cwd=repo,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    stdout, stderr = proc.communicate(timeout=120)
except subprocess.TimeoutExpired as error:
    os.killpg(proc.pid, signal.SIGTERM)
    try:
        stdout, stderr = proc.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        stdout, stderr = proc.communicate()
    stdout = stdout or error.stdout or ""
    stderr = stderr or error.stderr or ""
    (out / "stdout").write_text(stdout)
    (out / "stderr").write_text(stderr)
    (out / "native-exit.json").write_text(json.dumps({"native_exit": 124}) + "\n")
    raise SystemExit(124)

(out / "stdout").write_text(stdout or "")
(out / "stderr").write_text(stderr or "")
(out / "native-exit.json").write_text(json.dumps({"native_exit": proc.returncode}) + "\n")
print(stdout or "")
print(stderr or "", file=sys.stderr)
raise SystemExit(proc.returncode)
