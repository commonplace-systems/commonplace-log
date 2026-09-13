#!/usr/bin/env python3
"""Bounded local Wrangler bundle dry-run; root owns any future execution."""

import hashlib
import io
import json
import os
import pathlib
import signal
import subprocess
import sys
import tarfile
import time


ROOT = pathlib.Path(__file__).resolve().parents[3]
OUT = pathlib.Path(sys.argv[1]).resolve()
SOURCE_COMMIT = "4a22c1d65549577e42a12d390949d95e408eed2a"
PRODUCTION_CONFIG_REL = "worker/wrangler.jsonc"
PRODUCTION_CONFIG_SHA = "fdda2ea9a94af41d53f2aecc22c2683db0646088d8dff3bfb9e24d69bd6cc29a"
PRODUCTION_CONFIG_BASE = "76f9028"
NODE = pathlib.Path("/usr/bin/node")
WRANGLER_ROOT = pathlib.Path("/home/jes/commonplace-log/worker/node_modules")
WRANGLER = WRANGLER_ROOT / "wrangler/wrangler-dist/cli.js"
WRANGLER_PACKAGE = WRANGLER_ROOT / "wrangler/package.json"
WRANGLER_VERSION = "4.125.0"
WRANGLER_SHA = "8642ffb286871a94617969aa64d351097a49783361834d8c4aec75adbddfa773"
WRANGLER_PACKAGE_SHA = "2acd581fd6f773f5d5e2aab1433bac9ff5b40d352d18786503dfdfa009823eb8"
RUNTIME_COUNT = 3221
CHILD_TIMEOUT = 90
OUTER_TIMEOUT = 150
TERM_GRACE = 5
KILL_GRACE = 2
ROOT_CLEANUP_GRACE = 30

if len(sys.argv) != 2:
    raise SystemExit("usage: run_provider_worker_dry_run.py OUTPUT")
if OUT.exists():
    raise SystemExit(f"refusing existing output: {OUT}")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_files(path):
    return sorted(p for p in path.rglob("*") if p.is_file() and "node_modules" not in p.parts)


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True).strip()


def group_exists(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def check_source():
    if git("cat-file", "-t", SOURCE_COMMIT) != "commit":
        raise SystemExit("frozen provider source commit is unavailable")
    current_config = ROOT / PRODUCTION_CONFIG_REL
    archived_config = subprocess.check_output(["git", "-C", str(ROOT), "show", f"{SOURCE_COMMIT}:{PRODUCTION_CONFIG_REL}"])
    base_config = subprocess.check_output(["git", "-C", str(ROOT), "show", f"{PRODUCTION_CONFIG_BASE}:{PRODUCTION_CONFIG_REL}"])
    if sha256(current_config) != PRODUCTION_CONFIG_SHA:
        raise SystemExit("working production config hash differs from frozen config")
    if hashlib.sha256(archived_config).hexdigest() != PRODUCTION_CONFIG_SHA:
        raise SystemExit("source commit production config hash differs from frozen config")
    if hashlib.sha256(base_config).hexdigest() != PRODUCTION_CONFIG_SHA:
        raise SystemExit("recorded production config hash differs from frozen config")
    if subprocess.run(["git", "-C", str(ROOT), "diff", "--quiet", SOURCE_COMMIT, "HEAD", "--", "worker/src", "worker/package.json", "worker/package-lock.json", PRODUCTION_CONFIG_REL]).returncode != 0:
        raise SystemExit("current worker product differs from frozen source/config")
    if not NODE.is_file() or not WRANGLER.is_file() or not WRANGLER_PACKAGE.is_file():
        raise SystemExit("pinned Node or Wrangler installation is unavailable")
    if sha256(WRANGLER) != WRANGLER_SHA or sha256(WRANGLER_PACKAGE) != WRANGLER_PACKAGE_SHA:
        raise SystemExit("installed Wrangler bytes differ from frozen tool")
    package = json.loads(WRANGLER_PACKAGE.read_text())
    if package.get("version") != WRANGLER_VERSION:
        raise SystemExit("installed Wrangler version differs from frozen tool")
    runtime_files = [p for p in WRANGLER_ROOT.rglob("*") if p.is_file()]
    if len(runtime_files) != RUNTIME_COUNT:
        raise SystemExit(f"worker runtime membership mismatch: {len(runtime_files)}")


check_source()
OUT.mkdir(parents=True, mode=0o700)
OUT.chmod(0o700)
context = OUT / "context"
context.mkdir()
archive = subprocess.check_output(["git", "-C", str(ROOT), "archive", SOURCE_COMMIT, "worker", "commonplace_log"])
with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as tar:
    tar.extractall(context)
config = context / PRODUCTION_CONFIG_REL
if sha256(config) != PRODUCTION_CONFIG_SHA:
    raise SystemExit("materialized production config hash mismatch")
node_modules = context / "worker/node_modules"
node_modules.symlink_to(WRANGLER_ROOT)

bundle = OUT / "bundle"
metafile = OUT / "metafile.json"
command = [
    str(NODE), str(WRANGLER), "deploy",
    "--dry-run", "--outdir", str(bundle), "--metafile", str(metafile),
    "--containers-rollout=none", "--env-file=/dev/null",
    "--config", str(config),
]

files = {}


def add(label, path):
    if not path.is_file():
        raise SystemExit(f"missing input: {path}")
    if label in files:
        raise SystemExit(f"duplicate input: {label}")
    files[label] = path


for path in source_files(context):
    add(f"source/{path.relative_to(context)}", path)
add("production-config", config)
add("tool/node", NODE)
add("tool/wrangler-cli", WRANGLER)
add("tool/wrangler-package", WRANGLER_PACKAGE)
add("packet/runner", pathlib.Path(__file__))
add("packet/readme", pathlib.Path(__file__).with_name("README.md"))
add("packet/wrangler-command", pathlib.Path(__file__).with_name("wrangler-command.json"))
for path in sorted(p for p in WRANGLER_ROOT.rglob("*") if p.is_file()):
    add(f"worker-runtime/{path.relative_to(WRANGLER_ROOT)}", path)
pre = {label: sha256(path) for label, path in sorted(files.items())}
pre_runtime_paths = sorted(str(path.relative_to(WRANGLER_ROOT)) for path in WRANGLER_ROOT.rglob("*") if path.is_file())

OUT.joinpath("input-sha256.json").write_text(json.dumps(pre, indent=2, sort_keys=True) + "\n")
OUT.joinpath("source-pins.json").write_text(json.dumps({
    "source_commit": SOURCE_COMMIT,
    "production_config": PRODUCTION_CONFIG_REL,
    "production_config_sha256": PRODUCTION_CONFIG_SHA,
    "production_config_equal_commit": PRODUCTION_CONFIG_BASE,
    "wrangler_version": WRANGLER_VERSION,
    "wrangler_cli_sha256": WRANGLER_SHA,
    "wrangler_package_sha256": WRANGLER_PACKAGE_SHA,
    "runtime_root": str(WRANGLER_ROOT),
    "runtime_file_count": RUNTIME_COUNT,
    "mode": "dry-run",
    "containers_rollout": "none",
}, indent=2, sort_keys=True) + "\n")
OUT.joinpath("command.json").write_text(json.dumps({
    "argv": command,
    "cwd": str(context / "worker"),
    "child_timeout_seconds": CHILD_TIMEOUT,
    "outer_timeout_seconds": OUTER_TIMEOUT,
    "root_cleanup_grace_seconds": ROOT_CLEANUP_GRACE,
    "term_grace_seconds": TERM_GRACE,
    "kill_grace_seconds": KILL_GRACE,
    "upload": False,
}, indent=2, sort_keys=True) + "\n")

for name in ("home", "tmp"):
    (OUT / name).mkdir(mode=0o700)
env = {
    "PATH": "/usr/bin:/bin",
    "HOME": str(OUT / "home"),
    "TMPDIR": str(OUT / "tmp"),
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "CI": "1",
    "NO_COLOR": "1",
    "CLOUDFLARE_LOAD_DEV_VARS_FROM_DOT_ENV": "false",
    "WRANGLER_SEND_METRICS": "false",
}

owned = []
signal_received = None
finalizing = False
cleanup_started = False
blocked = {signal.SIGTERM, signal.SIGINT}


def on_signal(signum, _frame):
    global signal_received
    if signal_received is None:
        signal_received = signal.Signals(signum).name
    if not finalizing:
        raise KeyboardInterrupt(signal_received)


def stop(record):
    process = record["process"]
    if group_exists(record["pgid"]):
        try:
            os.killpg(record["pgid"], signal.SIGTERM)
            record["term_sent"] = True
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + TERM_GRACE
        while group_exists(record["pgid"]) and time.monotonic() < deadline:
            process.poll()
            time.sleep(0.05)
        if group_exists(record["pgid"]):
            try:
                os.killpg(record["pgid"], signal.SIGKILL)
                record["kill_sent"] = True
            except ProcessLookupError:
                pass
            deadline = time.monotonic() + KILL_GRACE
            while group_exists(record["pgid"]) and time.monotonic() < deadline:
                process.poll()
                time.sleep(0.05)
    record["leader_exit"] = process.poll()
    record["group_absent"] = not group_exists(record["pgid"])


def cleanup():
    global cleanup_started
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
    try:
        if cleanup_started:
            return
        cleanup_started = True
        for record in reversed(owned):
            try:
                stop(record)
            except BaseException as error:
                record["cleanup_error"] = repr(error)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def spawn():
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
    try:
        stdout = (OUT / "stdout").open("wb")
        stderr = (OUT / "stderr").open("wb")
        process = subprocess.Popen(command, cwd=context / "worker", env=env, stdout=stdout, stderr=stderr, start_new_session=True, preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, previous))
        record = {"label": "wrangler-dry-run", "pid": process.pid, "pgid": process.pid, "process": process, "term_sent": False, "kill_sent": False, "leader_exit": None, "group_absent": False}
        owned.append(record)
        return record, stdout, stderr
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


signal.signal(signal.SIGTERM, on_signal)
signal.signal(signal.SIGINT, on_signal)
child_rc = None
child_timeout = False
try:
    record, stdout_handle, stderr_handle = spawn()
    try:
        record["process"].wait(timeout=CHILD_TIMEOUT)
    except subprocess.TimeoutExpired:
        child_timeout = True
        stop(record)
    child_rc = record["process"].poll()
except KeyboardInterrupt:
    signal_received = signal_received or "SIGINT"
finally:
    finalizing = True
    cleanup()
    signal.pthread_sigmask(signal.SIG_UNBLOCK, blocked)
    if "stdout_handle" in locals():
        stdout_handle.close()
        stderr_handle.close()
    for item in owned:
        item.pop("process", None)
    groups_closed = bool(owned) and all(item.get("group_absent") and item.get("leader_exit") is not None for item in owned)
    cleanup_error = any(item.get("cleanup_error") for item in owned)
    forced_kill = any(item.get("kill_sent") for item in owned)
    native_info = {"child_rc": child_rc, "native_timeout": child_timeout, "signal_received": signal_received}
    OUT.joinpath("native.rc").write_text(json.dumps(native_info) + "\n")
    OUT.joinpath("process-groups.json").write_text(json.dumps({"groups": owned, "cleanup_in_finally": True, "term_grace_seconds": TERM_GRACE, "kill_grace_seconds": KILL_GRACE}, indent=2, sort_keys=True) + "\n")
    post = {}
    bundle_files = {}
    metafile_hash = None
    runtime_additions = []
    runtime_removals = []
    hash_error = None
    try:
        post = {label: sha256(path) for label, path in sorted(files.items()) if path.exists() and path.is_file()}
        bundle_files = {str(path.relative_to(bundle)): sha256(path) for path in sorted(bundle.rglob("*")) if path.is_file()} if bundle.is_dir() else {}
        metafile_hash = sha256(metafile) if metafile.is_file() else None
        post_runtime_paths = sorted(str(path.relative_to(WRANGLER_ROOT)) for path in WRANGLER_ROOT.rglob("*") if path.is_file())
        runtime_additions = sorted(set(post_runtime_paths) - set(pre_runtime_paths))
        runtime_removals = sorted(set(pre_runtime_paths) - set(post_runtime_paths))
        OUT.joinpath("bundle-sha256.json").write_text(json.dumps(bundle_files, indent=2, sort_keys=True) + "\n")
        OUT.joinpath("metafile-sha256.json").write_text(json.dumps({"path": str(metafile), "sha256": metafile_hash}, indent=2, sort_keys=True) + "\n")
        OUT.joinpath("post-input-sha256.json").write_text(json.dumps(post, indent=2, sort_keys=True) + "\n")
        OUT.joinpath("runtime-inventory.json").write_text(json.dumps({"pre_count": len(pre_runtime_paths), "post_count": len(post_runtime_paths), "added": runtime_additions, "removed": runtime_removals}, indent=2, sort_keys=True) + "\n")
    except BaseException as error:
        hash_error = repr(error)
    equal = hash_error is None and pre == post
    reasons = []
    if signal_received:
        reasons.append("runner received a signal")
    if child_timeout:
        reasons.append("dry-run child timed out")
    if child_rc != 0:
        reasons.append("dry-run child rc is not zero")
    if not groups_closed:
        reasons.append("owned process group closure was not proven")
    if forced_kill:
        reasons.append("owned process group required KILL")
    if cleanup_error:
        reasons.append("owned process cleanup raised an error")
    if not equal:
        reasons.append("input PRE/POST hash mismatch")
    if runtime_additions or runtime_removals:
        reasons.append("worker runtime membership changed")
    if hash_error:
        reasons.append("post-run hash or receipt generation failed")
    if not bundle_files:
        reasons.append("dry-run bundle was not produced")
    if metafile_hash is None:
        reasons.append("dry-run metafile was not produced")
    verdict = 0 if not reasons else 125
    OUT.joinpath("verdict.json").write_text(json.dumps({"verdict_rc": verdict, "reasons": reasons, "bundle_file_count": len(bundle_files), "metafile_sha256": metafile_hash, "hash_error": hash_error, "runtime_additions": runtime_additions, "runtime_removals": runtime_removals}, indent=2, sort_keys=True) + "\n")
raise SystemExit(verdict)
