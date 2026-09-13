import hashlib
import json
import os
import pathlib
import signal
import subprocess
import sys
import tarfile
import time


root = pathlib.Path(__file__).resolve().parents[3]
output = pathlib.Path(sys.argv[1]).resolve()
original_output = pathlib.Path(os.environ.get(
    "PROVIDER_RESTORE_EMPTY_OWNED_ORIGINAL_OUTPUT",
    str(root / "tmp/provider-restore-empty-owned-1"),
)).resolve()
if output.exists():
    raise SystemExit(f"refusing existing output: {output}")
output.mkdir(parents=True)
source = output / "source"
deps = pathlib.Path("/home/jes/commonplace-log/worker/node_modules")
base_commit = "5c7e3fe3ff5a33ce9fd0b4f4d1aa5e28216bcb4c"
runner = pathlib.Path(__file__).resolve()
test_file = root / "worker/test/realm/restore-empty-owned.workers.test.ts"
worker_inputs = [
    *sorted((root / "worker/src").rglob("*.ts")),
    test_file,
    root / "worker/vitest.workers.config.ts",
    root / "worker/wrangler.test.jsonc",
    root / "worker/package.json",
    root / "worker/package-lock.json",
    runner,
]
for path in worker_inputs:
    if not path.is_file():
        raise SystemExit(f"missing runner input: {path}")
if not (deps / "vitest/vitest.mjs").is_file():
    raise SystemExit(f"missing pinned worker dependencies: {deps}")
actual_head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
if subprocess.run(["git", "merge-base", "--is-ancestor", base_commit, actual_head], cwd=root).returncode != 0:
    raise SystemExit(f"HEAD {actual_head} is not based on required provider commit {base_commit}")
status_lines = subprocess.check_output(
    ["git", "status", "--porcelain", "--untracked-files=all"], cwd=root, text=True,
).splitlines()
unexpected_status = [line for line in status_lines if not line.startswith("?? tmp/")]
if unexpected_status:
    raise SystemExit("runner worktree has non-measurement changes: " + " ".join(unexpected_status))


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def retained_tree(root_path):
    files = []
    symlinks = []
    for path in sorted(root_path.rglob("*")):
        if path.is_symlink():
            symlinks.append(path.relative_to(root_path).as_posix())
        elif path.is_file():
            files.append({
                "path": path.relative_to(root_path).as_posix(),
                "bytes": path.stat().st_size,
                "sha256": sha256(path),
            })
    payload = {"files": files, "symlinks": symlinks}
    serialized = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return {
        "root": str(root_path),
        "file_count": len(files),
        "bytes": sum(item["bytes"] for item in files),
        "files": files,
        "symlinks": symlinks,
        "manifest_sha256": hashlib.sha256(serialized).hexdigest(),
    }


if not original_output.is_dir():
    raise SystemExit(f"missing retained original output: {original_output}")
original_audit = retained_tree(original_output)
(output / "original-audit.json").write_text(
    json.dumps(original_audit, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
)


def discover_runtime_files():
    return sorted(path for path in deps.rglob("*") if path.is_file())


pre_runtime_files = discover_runtime_files()
if not pre_runtime_files:
    raise SystemExit("empty worker dependency tree")


def hashes(runtime_files):
    return {
        "worker_source": {str(path.relative_to(root)): sha256(path) for path in worker_inputs},
        "worker_runtime": {str(path): sha256(path) for path in runtime_files},
    }


pre = hashes(pre_runtime_files)
(output / "input-sha256.json").write_text(json.dumps(pre, indent=2, sort_keys=True) + "\n")
(output / "source-pins.json").write_text(json.dumps({
    "runner_worktree_head": actual_head,
    "required_base_commit": base_commit,
    "worker_worktree": str(root),
    "test_file": str(test_file),
    "worker_runtime_root": str(deps),
    "worker_runtime_file_count": len(pre_runtime_files),
    "test_selection": ["worker/test/realm/restore-empty-owned.workers.test.ts"],
    "limits": {"test_timeout_seconds": 120, "term_grace_seconds": 5, "kill_grace_seconds": 2},
    "continuation": True,
    "original_output": str(original_output),
    "original_tree_manifest_sha256": original_audit["manifest_sha256"],
    "original_tree_file_count": original_audit["file_count"],
}, indent=2, sort_keys=True) + "\n")

archive = subprocess.Popen(["git", "archive", "--format=tar", actual_head], cwd=root, stdout=subprocess.PIPE)
with tarfile.open(fileobj=archive.stdout, mode="r|") as stream:
    stream.extractall(source)
if archive.wait() != 0:
    raise SystemExit("git archive failed")
(source / "worker/node_modules").symlink_to(deps)
cache_dir = output / "vite-cache"
cache_dir.mkdir(parents=True, exist_ok=True)
cache_literal = json.dumps(str(cache_dir))
(source / "worker/vitest.inventory.workers.config.ts").write_text(
    f'import base from "./vitest.workers.config.ts";\n'
    f'export default {{ ...base, cacheDir: {cache_literal}, test: {{ ...base.test, cache: {{ dir: {cache_literal} }} }} }};\n'
)
(source / "worker/vitest.inventory.config.ts").write_text(
    f'import base from "./vitest.config.ts";\n'
    f'const projects = base.test?.projects ?? [];\n'
    f'export default {{ ...base, cacheDir: {cache_literal}, test: {{ ...base.test, cache: {{ dir: {cache_literal} }}, projects: [projects[0], "./vitest.inventory.workers.config.ts"] }} }};\n'
)
command = [
    "/usr/bin/node", str(source / "worker/node_modules/vitest/vitest.mjs"), "run",
    "--config", str(source / "worker/vitest.inventory.config.ts"), "--project", "do",
    str(source / "worker/test/realm/restore-empty-owned.workers.test.ts"),
    "--reporter=json", "--outputFile", str(output / "test-result.json"),
]
(output / "command.json").write_text(json.dumps({
    "argv": command,
    "cwd": str(source / "worker"),
    "source_archive_head": actual_head,
    "continuation": True,
    "original_output": str(original_output),
    "original_tree_manifest_sha256": original_audit["manifest_sha256"],
    "test_timeout_seconds": 120,
    "term_grace_seconds": 5,
    "kill_grace_seconds": 2,
    "native_scope": "Cloudflare vitest worker pool with local SQLite-backed Durable Objects",
}, indent=2) + "\n")

for private_dir in (output / "home", output / "config", output / "tmp"):
    private_dir.mkdir(parents=True, exist_ok=True)
env = {
    "PATH": "/usr/bin:/bin",
    "HOME": str(output / "home"),
    "XDG_CONFIG_HOME": str(output / "config"),
    "TMPDIR": str(output / "tmp"),
    "WRANGLER_SEND_METRICS": "false",
    "CI": "1",
    "NO_COLOR": "1",
}
records = []
cleanup_in_progress = False
first_signal_received = False
retention_active = False
signal_exit_code = None
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
        for record in reversed(records):
            try:
                stop_record(record)
            except BaseException as error:
                record["cleanup_error"] = repr(error)
                record["forced_cleanup_hold"] = True
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def on_signal(signum, _frame):
    global first_signal_received, signal_exit_code
    if not first_signal_received:
        first_signal_received = True
        signal_exit_code = 128 + signum
    cleanup_all()
    if not retention_active:
        raise SystemExit(signal_exit_code)


signal.signal(signal.SIGTERM, on_signal)
signal.signal(signal.SIGINT, on_signal)

retention_active = True
stdout_handle = None
stderr_handle = None
process = None
record = None
spawn_error = None
wait_error = None
timed_out = False
previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, blocked_signals)
try:
    try:
        stdout_handle = (output / "stdout").open("wb")
        stderr_handle = (output / "stderr").open("wb")
        if first_signal_received:
            spawn_error = "signal latched before native spawn"
        else:
            process = subprocess.Popen(
                command, cwd=source / "worker", env=env,
                stdout=stdout_handle, stderr=stderr_handle,
                start_new_session=True,
                preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask),
            )
            record = {
                "label": "vitest-workers",
                "pid": process.pid,
                "pgid": process.pid,
                "term_sent": False,
                "kill_sent": False,
                "process": process,
            }
            records.append(record)
            (output / "process-start.json").write_text(json.dumps({
                "label": "vitest-workers",
                "pid": process.pid,
                "pgid": process.pid,
                "argv": command,
            }, indent=2) + "\n")
    except BaseException as error:
        spawn_error = repr(error)
finally:
    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

try:
    if process is not None and spawn_error is None:
        try:
            process.wait(timeout=120)
        except subprocess.TimeoutExpired:
            timed_out = True
            stop_record(record)
        except BaseException as error:
            wait_error = repr(error)
finally:
    cleanup_all()
    if stdout_handle is not None:
        stdout_handle.close()
    if stderr_handle is not None:
        stderr_handle.close()
    for stream in (output / "stdout", output / "stderr"):
        stream.touch(exist_ok=True)
    post_runtime_files = discover_runtime_files()
    post = hashes(post_runtime_files)
    (output / "post-sha256.json").write_text(json.dumps(post, indent=2, sort_keys=True) + "\n")
    equal = pre == post
    (output / "input-equality.json").write_text(json.dumps({"equal": equal}) + "\n")
    (output / "runtime-membership.json").write_text(json.dumps({
        "pre": [str(path) for path in pre_runtime_files],
        "post": [str(path) for path in post_runtime_files],
        "added": [str(path) for path in sorted(set(post_runtime_files) - set(pre_runtime_files))],
        "removed": [str(path) for path in sorted(set(pre_runtime_files) - set(post_runtime_files))],
    }, indent=2) + "\n")
    result = None
    result_path = output / "test-result.json"
    if result_path.is_file():
        try:
            result = json.loads(result_path.read_text())
        except (OSError, ValueError):
            pass
    test_ok = isinstance(result, dict) and result.get("numTotalTests") == 6 and \
        result.get("numPassedTests") == 6 and result.get("numFailedTests") == 0 and \
        result.get("numPendingTests") == 0
    cleanup_hold = any(
        record.get("forced_cleanup_hold") is not False
        or record.get("group_absent") is not True
        or not isinstance(record.get("leader_exit"), int)
        for record in records
    )
    test_rc = process.poll() if process is not None else None
    native_rc = test_rc if test_rc is not None else 125
    verdict = native_rc if signal_exit_code is None and spawn_error is None and wait_error is None and \
        equal and not timed_out and not cleanup_hold and native_rc == 0 and test_ok else 125
    (output / "native.rc").write_text(json.dumps({
        "test_rc": test_rc,
        "native_rc": native_rc,
        "timed_out": timed_out,
        "test_result_ok": test_ok,
        "forced_cleanup_hold": cleanup_hold,
        "spawn_error": spawn_error,
        "wait_error": wait_error,
        "signal_exit_code": signal_exit_code,
    }, indent=2) + "\n")
    (output / "verdict.rc").write_text(str(verdict) + "\n")
    for record in records:
        record.pop("process", None)
    (output / "process-groups.json").write_text(json.dumps({
        "groups": records,
        "first_signal_received": first_signal_received,
        "term_grace_seconds": 5,
        "kill_grace_seconds": 2,
        "cleanup_in_finally": True,
    }, indent=2, sort_keys=True) + "\n")
    retention_active = False
raise SystemExit(verdict)
