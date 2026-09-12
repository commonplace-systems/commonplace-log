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

native1 = pathlib.Path(
    os.environ.get(
        "RESTORE_BINDING_NATIVE1_OUT",
        str(repo / "tmp/restore-binding-native-1"),
    )
)
app_ebin = native1 / "app-ebin"
dep_ebin = native1 / "dependency-ebin"
if not app_ebin.is_dir() or not dep_ebin.is_dir():
    raise SystemExit(f"native1 emitted BEAM directories missing under {native1}")

test_file = repo / "commonplace_log/test/document_profile_test.exs"
test_name = 'restore rejects multiwriter and wrong-frontier requests before creating a target'
lines = test_file.read_text().splitlines()
selected_line = next(
    number for number, line in enumerate(lines, 1) if f'test "{test_name}"' in line
)

tracked_inputs = [
    pathlib.Path(__file__),
    repo / "docs/measurements/restore-binding-native-1/restore_binding_continue.exs",
    test_file,
    repo / "commonplace_log/mix.lock",
]

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

input_hashes = {str(path.relative_to(repo)): sha256(path) for path in tracked_inputs}
(out / "input-sha256.json").write_text(json.dumps(input_hashes, indent=2, sort_keys=True) + "\n")

elixir = "/home/jes/.asdf/installs/elixir/1.18.4-otp-27/bin/elixir"
script = repo / "docs/measurements/restore-binding-native-1/restore_binding_continue.exs"
cmd = [elixir, str(script), str(out), str(selected_line)]
(out / "command.json").write_text(
    json.dumps(
        {
            "argv": cmd,
            "cwd": str(repo),
            "selected_test": f"test {test_name}",
            "selected_line": selected_line,
            "native1_output": str(native1),
        },
        indent=2,
    )
    + "\n"
)
env = os.environ.copy()
env.update(
    {
        "RESTORE_BINDING_NATIVE1_APP_EBIN": str(app_ebin),
        "RESTORE_BINDING_NATIVE1_DEP_EBIN": str(dep_ebin),
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
    stdout, stderr = proc.communicate(timeout=90)
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
    (out / "native-exit.json").write_text(
        json.dumps({"native_exit": None, "timed_out": True, "timeout_exit": 124}) + "\n"
    )
    raise SystemExit(124)

post_hashes = {str(path.relative_to(repo)): sha256(path) for path in tracked_inputs}
(out / "input-sha256-post.json").write_text(json.dumps(post_hashes, indent=2, sort_keys=True) + "\n")
(out / "input-equality.json").write_text(
    json.dumps({"equal": post_hashes == input_hashes}, indent=2) + "\n"
)
(out / "stdout").write_text(stdout or "")
(out / "stderr").write_text(stderr or "")
(out / "native-exit.json").write_text(
    json.dumps({"native_exit": proc.returncode, "timed_out": False}) + "\n"
)
print(stdout or "")
print(stderr or "", file=sys.stderr)
raise SystemExit(proc.returncode)
