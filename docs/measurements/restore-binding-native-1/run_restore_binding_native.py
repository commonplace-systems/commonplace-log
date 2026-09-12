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
source_commit = subprocess.check_output(
    ["git", "rev-parse", "bc1ec30^{commit}"], cwd=repo, text=True
).strip()
actual_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
if subprocess.run(["git", "merge-base", "--is-ancestor", source_commit, actual_commit], cwd=repo).returncode:
    raise SystemExit(f"runner source {actual_commit} is not based on pinned source {source_commit}")

test_cases = [
    "test existing DocumentProfile lane keeps one writer across restart",
    "test restore preserves bytes and writer, then supports append and restart",
    "test pending marker fences ordinary owner calls and resumes without a writer sidecar",
    "test restore owner fences pending append, merge, and lease calls",
    "test existing unmarked log is refused without adding restore schema",
]
source_root = repo / "commonplace_log"
existing_test = source_root / "test/document_profile_test.exs"
existing_cases = [f"test {match}" for match in __import__("re").findall(r'test\s+"([^"]+)"', existing_test.read_text())]
test_cases = sorted(existing_cases + test_cases)

tracked_inputs = [
    repo / "docs/measurements/restore-binding-native-1/restore_binding_native.exs",
    pathlib.Path(__file__),
    source_root / "mix.exs",
    source_root / "mix.lock",
    existing_test,
]
tracked_inputs.extend(sorted((source_root / "lib").rglob("*.ex")))

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

input_hashes = {str(path.relative_to(repo)): sha256(path) for path in tracked_inputs}

for relative in subprocess.check_output(
    ["git", "ls-tree", "-r", "--name-only", source_commit, "commonplace_log/lib", "commonplace_log/mix.exs", "commonplace_log/mix.lock"],
    cwd=repo,
    text=True,
).splitlines():
    source_path = repo / relative
    source_blob = subprocess.check_output(["git", "show", f"{source_commit}:{relative}"], cwd=repo)
    if source_path.read_bytes() != source_blob:
        raise SystemExit(f"source input drifted from pinned revision: {relative}")
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

def write_post_input_audit():
    post_hashes = {str(path.relative_to(repo)): sha256(path) for path in tracked_inputs}
    (out / "input-sha256-post.json").write_text(json.dumps(post_hashes, indent=2, sort_keys=True) + "\n")
    (out / "input-equality.json").write_text(
        json.dumps({"equal": post_hashes == input_hashes}, indent=2) + "\n"
    )
    if post_hashes != input_hashes:
        raise SystemExit("input files changed during native run")

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
    write_post_input_audit()
    (out / "stdout").write_text(stdout)
    (out / "stderr").write_text(stderr)
    (out / "native-exit.json").write_text(
        json.dumps({"native_exit": None, "timed_out": True, "timeout_exit": 124}) + "\n"
    )
    raise SystemExit(124)

write_post_input_audit()
(out / "stdout").write_text(stdout or "")
(out / "stderr").write_text(stderr or "")
(out / "native-exit.json").write_text(
    json.dumps({"native_exit": proc.returncode, "timed_out": False}) + "\n"
)
print(stdout or "")
print(stderr or "", file=sys.stderr)
raise SystemExit(proc.returncode)
