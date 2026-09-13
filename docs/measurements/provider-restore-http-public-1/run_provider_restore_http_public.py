#!/usr/bin/env python3
"""Bounded local public-ingress worker runner.

This packet selects the new public restore fixture and exactly one updated
authorization contract assertion.  It uses the Cloudflare Vitest worker pool
against the archived provider source and the pinned local node_modules tree;
it does not call RealmStore.storageFetch directly.
"""

import hashlib
import json
import os
import pathlib
import signal
import subprocess
import sys
import tarfile
import time


ROOT = pathlib.Path(__file__).resolve().parents[3]
WORKER = ROOT / "worker"
PROVIDER_DEPS = pathlib.Path(os.environ.get(
    "RESTORE_HTTP_PUBLIC_WORKER_DEPS",
    "/home/jes/commonplace-log/worker/node_modules",
)).resolve()
PROVIDER_PRODUCT_COMMIT = "fe11cac5b14bec92b0d7ef71b5a1599b08a3dab2"
FIXTURE_COMMIT = "e760fb1b18f91fccbdfdd16156cd08636f5715ff"
TEST_FILE = "worker/test/realm/restore-public.workers.test.ts"
AUTH_FILE = "worker/test/realm/restore-wire.workers.test.ts"
FIXTURE_SHA256 = "851d8782c153d5cf40f4c78ce4462ce0e7d99d7d3f76cff24f64d96b7720142d"
AUTH_SHA256 = "fbc586699f246567450dad0f369317978ceb10449177ef6d5b2a6cf60d79fa5d"
AUTH_TITLE = "restore bundle wire requires realm authorization before accepting the bounded public restore route"
EXPECTED_CASES = [
    "authenticated public restore wire rejects missing, wrong, cross-realm, and deployment tokens before mutation",
    "authenticated public restore wire restores through public auth with exact bytes and idempotent replay",
    "authenticated public restore wire refuses a public restore into a nonempty target without writing a bundle",
    AUTH_TITLE,
]
FIXTURE_TITLES = EXPECTED_CASES[:3]
EXPECTED_TOTAL = 4
NATIVE_TIMEOUT = 180
TERM_GRACE = 5
KILL_GRACE = 2
RUNTIME_COUNT = 3221
MEASUREMENT_DIR = ROOT / "docs/measurements/provider-restore-http-public-1"
RUNNER = pathlib.Path(__file__).resolve()

if len(sys.argv) != 2:
    raise SystemExit("usage: run_provider_restore_http_public.py /absolute/fresh/output")
OUT = pathlib.Path(sys.argv[1]).resolve()
if OUT.exists():
    raise SystemExit(f"refusing existing output: {OUT}")


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True).strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_files(path):
    if path.is_file():
        return [path]
    return sorted(item for item in path.rglob("*") if item.is_file())


def verify_source():
    actual_head = git("rev-parse", "HEAD")
    if subprocess.run(
        ["git", "merge-base", "--is-ancestor", PROVIDER_PRODUCT_COMMIT, actual_head],
        cwd=ROOT,
    ).returncode != 0:
        raise SystemExit("provider source is not based on the accepted product commit")
    if subprocess.run(
        ["git", "diff", "--quiet", PROVIDER_PRODUCT_COMMIT, actual_head, "--",
         "worker/src", "worker/package.json", "worker/package-lock.json"],
        cwd=ROOT,
    ).returncode != 0:
        raise SystemExit("worker product differs from the accepted public-provider base")
    if subprocess.run(
        ["git", "merge-base", "--is-ancestor", FIXTURE_COMMIT, actual_head], cwd=ROOT,
    ).returncode != 0:
        raise SystemExit("provider source does not contain the reviewed public fixture commit")
    status = git("status", "--porcelain", "--untracked-files=all").splitlines()
    if status:
        raise SystemExit(f"provider worktree must be clean before archiving: {status}")
    for relative in (TEST_FILE, AUTH_FILE):
        if not (ROOT / relative).is_file():
            raise SystemExit(f"missing selected test file: {relative}")
    for relative, expected_sha in ((TEST_FILE, FIXTURE_SHA256), (AUTH_FILE, AUTH_SHA256)):
        path = ROOT / relative
        archived_bytes = subprocess.check_output(["git", "show", f"{FIXTURE_COMMIT}:{relative}"], cwd=ROOT)
        if hashlib.sha256(archived_bytes).hexdigest() != expected_sha or sha256(path) != expected_sha:
            raise SystemExit(f"selected fixture provenance mismatch: {relative}")
    if not (PROVIDER_DEPS / ".bin/vitest").is_file():
        raise SystemExit(f"missing pinned Vitest: {PROVIDER_DEPS}")
    for tool in (pathlib.Path("/usr/bin/node"), PROVIDER_DEPS / "wrangler/bin/wrangler.js", PROVIDER_DEPS / "vitest/vitest.mjs"):
        if not tool.is_file():
            raise SystemExit(f"missing pinned runner tool: {tool}")
    runtime_files = sorted(path for path in PROVIDER_DEPS.rglob("*") if path.is_file())
    if len(runtime_files) != RUNTIME_COUNT:
        raise SystemExit(f"worker runtime count mismatch: {len(runtime_files)} != {RUNTIME_COUNT}")
    return actual_head, runtime_files


actual_head, runtime_files = verify_source()
OUT.mkdir(parents=True)

# The archive is the only source loaded by the child.  The dependency tree is
# linked read-only from the accepted pinned installation and is hash-audited
# before and after the run.  No credentials or .dev.vars files are copied.
archive_path = OUT / "provider-source.tar"
with archive_path.open("wb") as archive_file:
    subprocess.run(["git", "archive", "--format=tar", actual_head], cwd=ROOT,
                   stdout=archive_file, check=True)
with tarfile.open(archive_path, mode="r:") as archive:
    archive.extractall(OUT / "provider-source")
archive_path.unlink()
source_root = OUT / "provider-source"
archived_worker = source_root / "worker"
(archived_worker / "node_modules").symlink_to(PROVIDER_DEPS)

source_inputs = [
    *source_files(WORKER / "src"),
    WORKER / TEST_FILE.removeprefix("worker/"),
    WORKER / AUTH_FILE.removeprefix("worker/"),
    WORKER / "vitest.config.ts",
    WORKER / "vitest.workers.config.ts",
    WORKER / "wrangler.test.jsonc",
    WORKER / "package.json",
    WORKER / "package-lock.json",
    RUNNER,
    MEASUREMENT_DIR / "README.md",
]
for path in source_inputs:
    if not path.is_file():
        raise SystemExit(f"missing runner input: {path}")


def discover_runtime():
    return sorted(path for path in PROVIDER_DEPS.rglob("*") if path.is_file())


def manifest(runtime_inputs):
    archived = [source_root / path.relative_to(ROOT) for path in source_inputs]
    return {
        "provider_source": {
            str(path.relative_to(ROOT)): sha256(path) for path in source_inputs
        },
        "archived_executed_source": {
            str(path.relative_to(source_root)): sha256(path) for path in archived
        },
        "worker_runtime": {
            str(path): sha256(path) for path in runtime_inputs
        },
        "tools": {str(path): sha256(path) for path in (
            pathlib.Path("/usr/bin/node"),
            PROVIDER_DEPS / "vitest/vitest.mjs",
            PROVIDER_DEPS / "wrangler/bin/wrangler.js",
        )},
    }


original_source_hashes = {
    str(path.relative_to(ROOT)): sha256(path) for path in source_inputs
}
archived_source_hashes = {
    str(path.relative_to(source_root)): sha256(source_root / path.relative_to(ROOT))
    for path in source_inputs
}
if archived_source_hashes != original_source_hashes:
    raise SystemExit("archived executed source differs from provider source inputs")
runtime_pre = discover_runtime()
pre = manifest(runtime_pre)
(OUT / "input-sha256.json").write_text(json.dumps(pre, indent=2, sort_keys=True) + "\n")
(OUT / "source-pins.json").write_text(json.dumps({
    "provider_worktree_head": actual_head,
    "provider_product_commit": PROVIDER_PRODUCT_COMMIT,
    "fixture_commit": FIXTURE_COMMIT,
    "fixture_sha256": FIXTURE_SHA256,
    "authorization_fixture_sha256": AUTH_SHA256,
    "worker_worktree": str(ROOT),
    "worker_runtime_root": str(PROVIDER_DEPS),
    "worker_runtime_file_count": len(runtime_files),
    "tool_paths": ["/usr/bin/node", str(PROVIDER_DEPS / "vitest/vitest.mjs"), str(PROVIDER_DEPS / "wrangler/bin/wrangler.js")],
    "test_file": TEST_FILE,
    "authorization_file": AUTH_FILE,
    "authorization_test_name": AUTH_TITLE,
    "expected_cases": EXPECTED_CASES,
    "expected_total": EXPECTED_TOTAL,
    "test_selection": {
        "fixture": [TEST_FILE],
        "authorization": [AUTH_FILE, "--testNamePattern", AUTH_TITLE],
    },
    "scope": "real handleIngress -> RealmContainer.fetch through the Vitest worker pool; no storageFetch bypass",
    "limits": {
        "native_timeout_seconds": NATIVE_TIMEOUT,
        "term_grace_seconds": TERM_GRACE,
        "kill_grace_seconds": KILL_GRACE,
    },
}, indent=2, sort_keys=True) + "\n")

node = "/usr/bin/node"
vitest = str(archived_worker / "node_modules/vitest/vitest.mjs")
config = str(archived_worker / "vitest.config.ts")
fixture_argv = [node, vitest, "run", "--config", config, "--project", "do",
                "test/realm/restore-public.workers.test.ts",
                "--reporter=json", "--outputFile", str(OUT / "fixture-result.json")]
auth_argv = [node, vitest, "run", "--config", config, "--project", "do",
             "test/realm/restore-wire.workers.test.ts", "--testNamePattern", AUTH_TITLE,
             "--reporter=json", "--outputFile", str(OUT / "authorization-result.json")]
(OUT / "command.json").write_text(json.dumps({
    "fixture_argv": fixture_argv,
    "authorization_argv": auth_argv,
    "cwd": str(archived_worker),
    "source_archive_head": actual_head,
    "native_timeout_seconds": NATIVE_TIMEOUT,
    "term_grace_seconds": TERM_GRACE,
    "kill_grace_seconds": KILL_GRACE,
    "native_scope": "Cloudflare Vitest worker pool, real public handleIngress and RealmContainer.fetch",
}, indent=2, sort_keys=True) + "\n")

for private_dir in (OUT / "home", OUT / "config", OUT / "tmp", OUT / "pool-cache"):
    private_dir.mkdir(parents=True, exist_ok=True)
env = {
    "PATH": "/usr/bin:/bin",
    "HOME": str(OUT / "home"),
    "XDG_CONFIG_HOME": str(OUT / "config"),
    "TMPDIR": str(OUT / "tmp"),
    "VITEST_CACHE_DIR": str(OUT / "pool-cache"),
    "WRANGLER_SEND_METRICS": "false",
    "CI": "1",
    "NO_COLOR": "1",
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
}

blocked = {signal.SIGTERM, signal.SIGINT}
owned = []
cleanup_started = False
finalizing = False
received_signal = None
received_signal_number = None
spawn_error = None


class RunnerSignal(Exception):
    pass


def group_exists(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def on_signal(signum, _frame):
    global received_signal, received_signal_number
    if received_signal is None:
        received_signal, received_signal_number = signal.Signals(signum).name, signum
    if not finalizing:
        raise RunnerSignal(received_signal)


def spawn(label, argv, stdout, stderr):
    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
    try:
        process = subprocess.Popen(
            argv, cwd=archived_worker, env=env, stdout=stdout, stderr=stderr,
            start_new_session=True,
            preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, old_mask),
        )
        record = {
            "label": label, "pid": process.pid, "pgid": process.pid,
            "term_sent": False, "kill_sent": False, "leader_exit": None,
            "group_absent": False, "forced_cleanup_hold": False, "process": process,
        }
        owned.append(record)
        return record
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)


def stop(record):
    process, pgid = record["process"], record["pgid"]
    if group_exists(pgid):
        try:
            os.killpg(pgid, signal.SIGTERM)
            record["term_sent"] = True
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + TERM_GRACE
        while group_exists(pgid) and time.monotonic() < deadline:
            process.poll()
            time.sleep(0.05)
        if group_exists(pgid):
            try:
                os.killpg(pgid, signal.SIGKILL)
                record["kill_sent"] = True
            except ProcessLookupError:
                pass
            deadline = time.monotonic() + KILL_GRACE
            while group_exists(pgid) and time.monotonic() < deadline:
                process.poll()
                time.sleep(0.05)
    record["leader_exit"] = process.poll()
    record["group_absent"] = not group_exists(pgid)
    record["forced_cleanup_hold"] = record["kill_sent"] or not record["group_absent"]


def cleanup():
    global cleanup_started
    if cleanup_started:
        return
    cleanup_started = True
    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
    try:
        for record in reversed(owned):
            try:
                stop(record)
            except BaseException as error:
                record["cleanup_error"] = repr(error)
                record["forced_cleanup_hold"] = True
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)


def summarize(result_path):
    try:
        result = json.loads(result_path.read_text())
    except (OSError, ValueError):
        return {"total": 0, "passed": 0, "failed": 0, "pending": 0, "assertions": [], "raw": None}
    assertions = []
    for suite in result.get("testResults", []) if isinstance(result, dict) else []:
        for assertion in suite.get("assertionResults", []):
            assertions.append({
                "full_name": assertion.get("fullName", ""),
                "title": assertion.get("title", ""),
                "status": assertion.get("status", ""),
            })
    if isinstance(result, dict) and "numTotalTests" in result:
        return {
            "total": int(result.get("numTotalTests", 0)),
            "passed": int(result.get("numPassedTests", 0)),
            "failed": int(result.get("numFailedTests", 0)),
            "pending": int(result.get("numPendingTests", 0)),
            "assertions": assertions,
            "raw": result,
        }
    return {"total": 0, "passed": 0, "failed": 1, "pending": 0, "assertions": assertions, "raw": result}


def selected_result_ok(summary, expected_titles):
    assertions = summary.get("assertions", [])
    if not assertions:
        return False
    selected = [item for item in assertions if item["full_name"] in expected_titles]
    passed_names = {item["full_name"] for item in assertions if item["status"] == "passed"}
    unexpected_active = [
        item for item in assertions
        if item["full_name"] not in expected_titles
        and item["status"] in {"passed", "failed", "todo", "pending"}
    ]
    return (
        len(selected) == len(expected_titles)
        and passed_names == set(expected_titles)
        and not unexpected_active
        and all(item["status"] == "passed"
                for item in selected)
    )


signal.signal(signal.SIGTERM, on_signal)
signal.signal(signal.SIGINT, on_signal)
results = []
native_rc = None
timed_out = False
try:
    for label, argv, stdout_name, stderr_name, result_name in (
        ("public-fixture", fixture_argv, "fixture-stdout", "fixture-stderr", "fixture-result.json"),
        ("authorization-contract", auth_argv, "authorization-stdout", "authorization-stderr", "authorization-result.json"),
    ):
        if received_signal is not None:
            raise RunnerSignal(received_signal)
        with (OUT / stdout_name).open("wb") as stdout, (OUT / stderr_name).open("wb") as stderr:
            record = spawn(label, argv, stdout, stderr)
            try:
                record["process"].wait(timeout=NATIVE_TIMEOUT)
            except subprocess.TimeoutExpired:
                timed_out = True
                stop(record)
            result_rc = record["process"].poll()
            summary = summarize(OUT / result_name)
            expected_titles = FIXTURE_TITLES if label == "public-fixture" else [AUTH_TITLE]
            summary["selected_ok"] = selected_result_ok(summary, expected_titles)
            results.append({"label": label, "rc": result_rc, **summary})
            if result_rc not in (0, None) or not summary["selected_ok"]:
                # Do not launch a second suite after the public fixture has
                # already failed; its result remains the authoritative failure.
                if label == "public-fixture":
                    break
                native_rc = result_rc
except RunnerSignal:
    pass
except BaseException as error:
    spawn_error = repr(error)
finally:
    finalizing = True
    final_mask = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
    try:
        cleanup()
        signal.pthread_sigmask(signal.SIG_SETMASK, final_mask)
        final_mask = None
        for path in (OUT / "fixture-stdout", OUT / "fixture-stderr", OUT / "authorization-stdout", OUT / "authorization-stderr"):
            path.touch(exist_ok=True)
        runtime_post = discover_runtime()
        post = manifest(runtime_post)
        (OUT / "post-sha256.json").write_text(json.dumps(post, indent=2, sort_keys=True) + "\n")
        equal = post == pre
        (OUT / "input-equality.json").write_text(json.dumps({"equal": equal}) + "\n")
        (OUT / "runtime-membership.json").write_text(json.dumps({
            "pre": [str(path) for path in runtime_pre],
            "post": [str(path) for path in runtime_post],
            "added": [str(path) for path in sorted(set(runtime_post) - set(runtime_pre))],
            "removed": [str(path) for path in sorted(set(runtime_pre) - set(runtime_post))],
        }, indent=2, sort_keys=True) + "\n")
        clean_records = [{key: value for key, value in item.items() if key != "process"} for item in owned]
        if native_rc is None and owned:
            native_rc = owned[-1]["process"].poll()
        expected = (
            len(results) == 2
            and results[0]["selected_ok"] and results[0]["failed"] == 0
            and results[1]["selected_ok"] and results[1]["failed"] == 0
            and results[0]["total"] >= 3 and results[1]["total"] >= 1
        )
        cleanup_hold = any(item.get("forced_cleanup_hold") for item in clean_records)
        reasons = []
        verdict = 0
        if received_signal is not None:
            verdict, reasons = 128 + int(received_signal_number), [f"runner received {received_signal}"]
        if native_rc != 0:
            verdict = native_rc if native_rc is not None else 125
            reasons.append("selected Vitest process returned nonzero")
        if timed_out:
            verdict, reasons = 124, reasons + ["selected Vitest process timed out"]
        if spawn_error is not None:
            verdict, reasons = 125, reasons + ["runner exception: " + spawn_error]
        if cleanup_hold or len(clean_records) != 2 or any(not item.get("group_absent") for item in clean_records):
            verdict, reasons = 125, reasons + ["owned process cleanup not proven"]
        if not equal:
            verdict, reasons = 125, reasons + ["source/runtime input mismatch"]
        if not expected:
            verdict, reasons = 125, reasons + ["selected test counts are not exactly 3+1 green"]
        (OUT / "native-exit.json").write_text(json.dumps({
            "native_rc": native_rc, "results": results, "expected": expected,
            "timed_out": timed_out, "owned": clean_records,
            "received_signal": received_signal,
        }, indent=2, sort_keys=True) + "\n")
        (OUT / "process-groups.json").write_text(json.dumps({
            "groups": clean_records, "cleanup_finally": True,
            "term_grace_seconds": TERM_GRACE, "kill_grace_seconds": KILL_GRACE,
        }, indent=2, sort_keys=True) + "\n")
        (OUT / "verdict.json").write_text(json.dumps({
            "native_rc": native_rc, "verdict_rc": verdict, "reasons": reasons,
            "expected_total": EXPECTED_TOTAL, "expected_cases": EXPECTED_CASES,
        }, indent=2, sort_keys=True) + "\n")
        (OUT / "native.rc").write_text("absent\n" if native_rc is None else f"{native_rc}\n")
        (OUT / "verdict.rc").write_text(f"{verdict}\n")
    finally:
        if final_mask is not None:
            signal.pthread_sigmask(signal.SIG_SETMASK, final_mask)

raise SystemExit(verdict)
