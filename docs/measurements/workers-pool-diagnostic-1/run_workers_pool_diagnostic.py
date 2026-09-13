#!/usr/bin/env python3
"""Two-arm request-stream observation runner; native execution is root-owned."""

import hashlib
import io
import json
import os
import pathlib
import re
import signal
import subprocess
import sys
import tarfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]
OUT = pathlib.Path(sys.argv[1]).resolve()
PROVIDER_DEPS = pathlib.Path("/home/jes/commonplace-log/worker/node_modules")
NODE = pathlib.Path("/usr/bin/node")
VITEST = PROVIDER_DEPS / "vitest/vitest.mjs"
RUNTIME_COUNT = 3221
FIXTURE_COMMIT = "cc8afaac0f84fde21a621e37300cf0cb755d47ca"
FIXTURE_REL = "worker/test/realm/allocation_registry.workers.test.ts"
FIXTURE_SHA = "d0a499d49e78f109f4e5af224537405d86a4f23aec081e5a204f92cd5f9a1bc0"
ARMS = (
    {
        "name": "baseline-ingress",
        "source_commit": "76f9028112feeba557e4d45060f1cbdead98e7f3",
        "test_file": "worker/test/realm/ingress.workers.test.ts",
        "test_name": "realm ingress requires the deployment token for create",
        "full_name": "realm ingress requires the deployment token for create",
        "excluded_count": 10,
    },
    {
        "name": "candidate-allocation",
        "source_commit": "4a22c1d65549577e42a12d390949d95e408eed2a",
        "test_file": FIXTURE_REL,
        "test_name": "deployed-base allocation and registry requires the deployment bearer and never treats a read capability as allocation authority",
        "full_name": "deployed-base allocation and registry requires the deployment bearer and never treats a read capability as allocation authority",
        "excluded_count": 5,
    },
)
CHILD_TIMEOUT = 60
TERM_GRACE = 5
KILL_GRACE = 2
EXTERNAL_OUTER = 210
EXTERNAL_CLEANUP = 30

if OUT.exists():
    raise SystemExit(f"refusing existing output: {OUT}")
if not PROVIDER_DEPS.is_dir() or not NODE.is_file() or not VITEST.is_file():
    raise SystemExit("installed worker runtime is unavailable")
if len([p for p in PROVIDER_DEPS.rglob("*") if p.is_file()]) != RUNTIME_COUNT:
    raise SystemExit("worker runtime membership count mismatch")


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True).strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_files(path):
    return sorted(p for p in path.rglob("*") if p.is_file())


for arm in ARMS:
    if subprocess.run(["git", "cat-file", "-e", arm["source_commit"]], cwd=ROOT).returncode != 0:
        raise SystemExit(f"source commit unavailable: {arm['name']}")
if subprocess.run(["git", "cat-file", "-e", FIXTURE_COMMIT], cwd=ROOT).returncode != 0:
    raise SystemExit("fixture commit unavailable")
fixture_bytes = subprocess.check_output(["git", "show", f"{FIXTURE_COMMIT}:{FIXTURE_REL}"], cwd=ROOT)
if hashlib.sha256(fixture_bytes).hexdigest() != FIXTURE_SHA:
    raise SystemExit("fixture hash mismatch")

OUT.mkdir(parents=True)
blocked = {signal.SIGTERM, signal.SIGINT}
signal_received = None
current_owned = []
finalizing = False


def on_signal(signum, _frame):
    global signal_received
    if signal_received is None:
        signal_received = signal.Signals(signum).name
    if not finalizing:
        raise KeyboardInterrupt(signal_received)


def group_exists(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


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
    record["forced_cleanup_hold"] = record["kill_sent"] or not record["group_absent"]


def spawn(argv, cwd, env, stdout, stderr, label):
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
    try:
        process = subprocess.Popen(
            argv,
            cwd=cwd,
            env=env,
            stdout=stdout,
            stderr=stderr,
            start_new_session=True,
            preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, previous),
        )
        record = {"label": label, "pid": process.pid, "pgid": process.pid, "process": process, "term_sent": False, "kill_sent": False}
        current_owned.append(record)
        return record
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def manifest(files):
    return {label: sha256(path) for label, path in sorted(files.items())}


def collect_assertions(path):
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return []
    found = []

    def walk(item):
        if isinstance(item, dict):
            if isinstance(item.get("fullName"), str) and isinstance(item.get("status"), str):
                found.append({"fullName": item["fullName"], "status": item["status"]})
            for child in item.values():
                walk(child)
        elif isinstance(item, list):
            for child in item:
                walk(child)

    walk(value)
    return found


def run_arm(arm):
    arm_out = OUT / arm["name"]
    arm_out.mkdir()
    context = arm_out / "context"
    context.mkdir()
    archive = subprocess.check_output(
        ["git", "archive", arm["source_commit"], "worker/src", "worker/test/realm", "worker/package.json", "worker/package-lock.json", "worker/vitest.workers.config.ts", "worker/wrangler.test.jsonc", "worker/tsconfig.workers.json"],
        cwd=ROOT,
    )
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as tar:
        tar.extractall(context)
    if arm["test_file"] == FIXTURE_REL:
        fixture = context / FIXTURE_REL
        fixture.parent.mkdir(parents=True, exist_ok=True)
        fixture.write_bytes(fixture_bytes)
    config = context / "worker/wrangler.test.jsonc"
    config_text = config.read_text()
    if "REALM_CONTAINER" not in config_text or "REALM_REGISTRY" not in config_text:
        raise SystemExit(f"required bindings absent: {arm['name']}")
    root_cache = arm_out / "root-cache"
    worker_cache = arm_out / "worker-cache"
    runner_config = context / "worker/vitest.workers.runner.config.ts"
    runner_config.write_text(
        'import { mergeConfig } from "vitest/config";\n'
        'import base from "./vitest.workers.config.ts";\n'
        f'export default mergeConfig(base, {{ cacheDir: {json.dumps(str(root_cache))}, test: {{ cache: {{ dir: {json.dumps(str(worker_cache))} }} }} }});\n'
    )
    (context / "worker/node_modules").symlink_to(PROVIDER_DEPS)
    relative_test = str(pathlib.Path(arm["test_file"]).relative_to("worker"))
    pattern = re.escape(arm["test_name"])
    command = [str(NODE), str(VITEST), "run", "--config", str(runner_config), "--testNamePattern", pattern, "--reporter=json", "--outputFile", str(arm_out / "vitest-results.json"), "--bail=1", relative_test]
    files = {}

    def add(label, path):
        if not path.is_file():
            raise SystemExit(f"missing arm input: {path}")
        files[label] = path

    for path in source_files(context):
        add(f"context/{path.relative_to(context)}", path)
    add("runner/run_workers_pool_diagnostic.py", pathlib.Path(__file__))
    add("runner/vitest.workers.runner.config.ts", runner_config)
    for path in source_files(PROVIDER_DEPS):
        add(f"worker-runtime/{path.relative_to(PROVIDER_DEPS)}", path)
    add("tool/node", NODE)
    add("tool/vitest", VITEST)
    pre = manifest(files)
    (arm_out / "input-sha256.json").write_text(json.dumps(pre, indent=2, sort_keys=True) + "\n")
    (arm_out / "command.json").write_text(json.dumps({
        "arm": arm["name"],
        "source_commit": arm["source_commit"],
        "test_file": arm["test_file"],
        "test_name": arm["test_name"],
        "argv": command,
        "cwd": str(context / "worker"),
        "child_timeout_seconds": CHILD_TIMEOUT,
        "external_outer_seconds": EXTERNAL_OUTER,
        "external_cleanup_seconds": EXTERNAL_CLEANUP,
        "term_grace_seconds": TERM_GRACE,
        "kill_grace_seconds": KILL_GRACE,
    }, indent=2, sort_keys=True) + "\n")
    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": str(arm_out / "home"),
        "TMPDIR": str(arm_out / "tmp"),
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "CI": "1",
        "NO_COLOR": "1",
        "CLOUDFLARE_LOAD_DEV_VARS_FROM_DOT_ENV": "false",
    }
    (arm_out / "home").mkdir()
    (arm_out / "tmp").mkdir()
    stdout_path, stderr_path = arm_out / "stdout", arm_out / "stderr"
    record = None
    timed_out = False
    spawn_error = None
    try:
        with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
            try:
                record = spawn(command, context / "worker", env, stdout, stderr, arm["name"])
                try:
                    record["process"].wait(timeout=CHILD_TIMEOUT)
                except subprocess.TimeoutExpired:
                    timed_out = True
                    stop(record)
            except KeyboardInterrupt:
                raise
            except BaseException as error:
                spawn_error = repr(error)
    except KeyboardInterrupt:
        pass
    except BaseException as error:
        spawn_error = spawn_error or repr(error)
    finally:
        if record is not None:
            stop(record)
        stdout_path.touch(exist_ok=True)
        stderr_path.touch(exist_ok=True)
        post_runtime_names = sorted(str(path.relative_to(PROVIDER_DEPS)) for path in PROVIDER_DEPS.rglob("*") if path.is_file())
        pre_runtime_names = sorted(label.removeprefix("worker-runtime/") for label in pre if label.startswith("worker-runtime/"))
        additions = sorted(set(post_runtime_names) - set(pre_runtime_names))
        removals = sorted(set(pre_runtime_names) - set(post_runtime_names))
        post_error = None
        try:
            post = manifest(files)
        except BaseException as error:
            post, post_error = {}, repr(error)
        equal = post_error is None and post == pre
        (arm_out / "input-sha256-post.json").write_text(json.dumps(post, indent=2, sort_keys=True) + "\n")
        (arm_out / "input-equality.json").write_text(json.dumps({"equal": equal, "input_count": len(pre)}) + "\n")
        (arm_out / "runtime-inventory.json").write_text(json.dumps({"pre_count": len(pre_runtime_names), "post_count": len(post_runtime_names), "added": additions, "removed": removals}, indent=2, sort_keys=True) + "\n")
        assertions = collect_assertions(arm_out / "vitest-results.json")
        selected_results = [item for item in assertions if item["fullName"] == arm["full_name"]]
        excluded_results = [item for item in assertions if item["fullName"] != arm["full_name"]]
        result_ok = (
            len(selected_results) == 1
            and selected_results[0]["status"] == "passed"
            and len(excluded_results) == arm["excluded_count"]
            and all(item["status"] in {"pending", "skipped"} for item in excluded_results)
            and len(assertions) == 1 + arm["excluded_count"]
        )
        diagnostics = [
            line
            for path in (stdout_path, stderr_path)
            for line in path.read_text(errors="replace").splitlines()
            if "request stream" in line.lower() or "stream error" in line.lower()
        ]
        native_rc = None if record is None else record["process"].poll()
        reasons = []
        if native_rc != 0: reasons.append("child rc is not zero")
        if timed_out: reasons.append("child timed out")
        if spawn_error: reasons.append("child spawn failed")
        if not result_ok: reasons.append("selected one-case result is not exactly passed")
        if not equal: reasons.append("input PRE/POST mismatch")
        if post_error: reasons.append("POST hashing failed")
        if additions or removals: reasons.append("runtime membership changed")
        if signal_received: reasons.append("runner received a signal")
        if record is None or record.get("forced_cleanup_hold") or not record.get("group_absent"): reasons.append("process-group cleanup not proven")
        arm_record = {key: value for key, value in (record or {}).items() if key != "process"}
        arm_result = {
            "arm": arm["name"],
            "source_commit": arm["source_commit"],
            "test_name": arm["test_name"],
            "native_rc": native_rc,
            "result_ok": result_ok,
            "diagnostic_count": len(diagnostics),
            "diagnostics": diagnostics,
            "diagnostic_scope": "This arm only; no localization beyond the two selected probes.",
            "reasons": reasons,
            "process_group": arm_record,
            "runtime_additions": additions,
            "runtime_removals": removals,
            "input_equal": equal,
            "timed_out": timed_out,
            "spawn_error": spawn_error,
            "observation_rc": 0 if result_ok and equal and not reasons else 125,
        }
        (arm_out / "result.json").write_text(json.dumps(arm_result, indent=2, sort_keys=True) + "\n")
        return arm_result


for signum in (signal.SIGTERM, signal.SIGINT):
    signal.signal(signum, on_signal)
arm_results = []
try:
    for arm in ARMS:
        arm_result = run_arm(arm)
        arm_results.append(arm_result)
        if arm_result["reasons"] or signal_received:
            break
finally:
    finalizing = True
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
    try:
        for record in reversed(current_owned):
            if not record.get("group_absent"):
                stop(record)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)

all_arms_observed = len(arm_results) == len(ARMS) and all(item["observation_rc"] == 0 for item in arm_results)
(OUT / "summary.json").write_text(json.dumps({
    "purpose": "two exact request-stream observation probes; no broad-suite localization claim",
    "arms": arm_results,
    "all_arms_observed": all_arms_observed,
    "first_signal_received": signal_received,
}, indent=2, sort_keys=True) + "\n")
raise SystemExit(0 if all_arms_observed and not signal_received else 125)
