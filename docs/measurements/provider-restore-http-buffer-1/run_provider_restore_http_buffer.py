#!/usr/bin/env python3
"""Bounded one-case Vitest runner for public ingress buffering."""

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
    "RESTORE_HTTP_BUFFER_WORKER_DEPS",
    "/home/jes/commonplace-log/worker/node_modules",
)).resolve()
SOURCE_BASE = "a15a9f4cdbab111db2a1c7fb979203b23732113b"
BUFFER_SOURCE = "f5f860c8ae2b47da39fb08018d29834ba70500b4"
FIXTURE_COMMIT = "0c303e24a60a8dfae4368c2e6c9fe436fe984034"
FIXTURE_SOURCE_COMMIT = "fbe5056e2b84f4bda3c10b4e2f03f33aca09a8eb"
TEST_FILE = "worker/test/realm/restore-public-buffering.workers.test.ts"
FIXTURE_FULL_NAME = (
    "public ingress body buffering rejects wrong-secret bodies, then serves "
    "inventory and restore, while bounding overflow before auth"
)
FORBIDDEN_STDERR = "Can't read from request stream after response has been sent"
NATIVE_TIMEOUT = 180
TERM_GRACE = 5
KILL_GRACE = 2
MEASUREMENT_DIR = ROOT / "docs/measurements/provider-restore-http-buffer-1"
RUNNER = pathlib.Path(__file__).resolve()

if len(sys.argv) != 2:
    raise SystemExit("usage: run_provider_restore_http_buffer.py /absolute/fresh/output")
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
    for commit, label in ((SOURCE_BASE, "source base"), (BUFFER_SOURCE, "buffer source"), (FIXTURE_COMMIT, "fixture")):
        if subprocess.run(["git", "merge-base", "--is-ancestor", commit, actual_head], cwd=ROOT).returncode != 0:
            raise SystemExit(f"provider source is not based on the accepted {label} commit")
    changed = git("diff", "--name-only", SOURCE_BASE, actual_head, "--", "worker/src", "worker/package.json", "worker/package-lock.json").splitlines()
    expected_product = {"worker/src/index.ts"}
    if set(changed) != expected_product:
        raise SystemExit(f"unexpected worker product changes: {changed}")
    fixture_changed = git("diff", "--name-only", BUFFER_SOURCE, actual_head, "--").splitlines()
    if fixture_changed != [TEST_FILE]:
        raise SystemExit(f"unexpected post-buffer source changes: {fixture_changed}")
    status = git("status", "--porcelain", "--untracked-files=all").splitlines()
    disallowed = [line for line in status if not line.startswith("?? tmp/")]
    if disallowed:
        raise SystemExit(f"provider worktree has disallowed changes: {disallowed}")
    if not (ROOT / TEST_FILE).is_file():
        raise SystemExit(f"missing selected test file: {TEST_FILE}")
    fixture_bytes = subprocess.check_output(["git", "show", f"{FIXTURE_COMMIT}:{TEST_FILE}"], cwd=ROOT)
    fixture_hash = hashlib.sha256(fixture_bytes).hexdigest()
    if fixture_hash != hashlib.sha256(subprocess.check_output(["git", "show", f"{FIXTURE_SOURCE_COMMIT}:{TEST_FILE}"], cwd=ROOT)).hexdigest():
        raise SystemExit("fixture cherry-pick changed its reviewed bytes")
    if sha256(ROOT / TEST_FILE) != fixture_hash:
        raise SystemExit("selected fixture bytes differ from the committed fixture")
    if not (PROVIDER_DEPS / ".bin/vitest").is_file():
        raise SystemExit(f"missing pinned Vitest: {PROVIDER_DEPS}")
    for tool in (pathlib.Path("/usr/bin/node"), PROVIDER_DEPS / "vitest/vitest.mjs"):
        if not tool.is_file():
            raise SystemExit(f"missing pinned runner tool: {tool}")
    runtime_files = sorted(path for path in PROVIDER_DEPS.rglob("*") if path.is_file())
    return actual_head, fixture_hash, runtime_files


actual_head, fixture_hash, runtime_files = verify_source()
OUT.mkdir(parents=True)
source_archive = OUT / "provider-source.tar"
with source_archive.open("wb") as archive_file:
    subprocess.run(["git", "archive", "--format=tar", actual_head], cwd=ROOT, stdout=archive_file, check=True)
with tarfile.open(source_archive, mode="r:") as archive:
    archive.extractall(OUT / "provider-source")
source_archive.unlink()
source_root = OUT / "provider-source"
archived_worker = source_root / "worker"
(archived_worker / "node_modules").symlink_to(PROVIDER_DEPS)

vite_root_cache = OUT / "vite-cache-root"
vite_worker_cache = OUT / "vite-cache-worker"
vite_root_cache.mkdir(parents=True)
vite_worker_cache.mkdir(parents=True)
root_config = archived_worker / "vitest.buffer.config.ts"
worker_config = archived_worker / "vitest.buffer.workers.config.ts"
worker_config.write_text(f'''import {{ defineWorkersProject }} from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersProject({{
  cacheDir: {json.dumps(str(vite_worker_cache))},
  test: {{
    name: "do",
    include: ["test/realm/restore-public-buffering.workers.test.ts"],
    poolOptions: {{
      workers: {{
        wrangler: {{ configPath: "./wrangler.test.jsonc" }},
        miniflare: {{ bindings: {{ GATEWAY_TOKEN: "test-gateway-token" }} }},
      }},
    }},
  }},
}});
''')
root_config.write_text(f'''import {{ defineConfig }} from "vitest/config";

export default defineConfig({{
  cacheDir: {json.dumps(str(vite_root_cache))},
  test: {{ projects: ["./vitest.buffer.workers.config.ts"] }},
}});
''')

source_inputs = [
    *source_files(WORKER / "src"),
    WORKER / TEST_FILE.removeprefix("worker/"),
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


def runtime_manifest(paths):
    return {str(path.relative_to(PROVIDER_DEPS)): sha256(path) for path in paths}


def manifest(paths):
    archived = [source_root / path.relative_to(ROOT) for path in source_inputs]
    generated = {str(path.relative_to(source_root)): sha256(path) for path in (root_config, worker_config)}
    return {
        "source": {str(path.relative_to(ROOT)): sha256(path) for path in source_inputs},
        "archived_source": {str(path.relative_to(source_root)): sha256(path) for path in archived},
        "generated_configs": generated,
        "runtime": runtime_manifest(paths),
        "tools": {str(path): sha256(path) for path in (pathlib.Path("/usr/bin/node"), PROVIDER_DEPS / "vitest/vitest.mjs")},
    }


runtime_pre = sorted(path for path in PROVIDER_DEPS.rglob("*") if path.is_file())
pre = manifest(runtime_pre)
(OUT / "input-sha256.json").write_text(json.dumps(pre, indent=2, sort_keys=True) + "\n")
(OUT / "source-pins.json").write_text(json.dumps({
    "provider_worktree_head": actual_head,
    "buffer_source": BUFFER_SOURCE,
    "source_base": SOURCE_BASE,
    "fixture_commit": FIXTURE_COMMIT,
    "fixture_source_commit": FIXTURE_SOURCE_COMMIT,
    "fixture_sha256": fixture_hash,
    "test_file": TEST_FILE,
    "expected_full_name": FIXTURE_FULL_NAME,
    "expected_total": 1,
    "forbidden_stderr": FORBIDDEN_STDERR,
    "runtime_root": str(PROVIDER_DEPS),
    "runtime_file_count": len(runtime_pre),
    "cache_dirs": {"root": str(vite_root_cache), "worker": str(vite_worker_cache)},
    "scope": "one public SELF ingress buffering case; no storageFetch bypass and no baseline replay",
}, indent=2, sort_keys=True) + "\n")

node = "/usr/bin/node"
vitest = str(archived_worker / "node_modules/vitest/vitest.mjs")
test_result = OUT / "fixture-result.json"
argv = [node, vitest, "run", "--config", str(root_config), "--project", "do",
        "test/realm/restore-public-buffering.workers.test.ts",
        "--reporter=json", "--outputFile", str(test_result)]
(OUT / "command.json").write_text(json.dumps({
    "argv": argv,
    "cwd": str(archived_worker),
    "source_archive_head": actual_head,
    "native_timeout_seconds": NATIVE_TIMEOUT,
    "term_grace_seconds": TERM_GRACE,
    "kill_grace_seconds": KILL_GRACE,
    "native_scope": "Cloudflare Vitest worker pool, actual src/index.ts -> REALM_CONTAINER",
}, indent=2, sort_keys=True) + "\n")

for private_dir in (OUT / "home", OUT / "config", OUT / "tmp"):
    private_dir.mkdir(parents=True, exist_ok=True)
env = {
    "PATH": "/usr/bin:/bin",
    "HOME": str(OUT / "home"),
    "XDG_CONFIG_HOME": str(OUT / "config"),
    "TMPDIR": str(OUT / "tmp"),
    "VITEST_CACHE_DIR": str(vite_root_cache),
    "WRANGLER_SEND_METRICS": "false",
    "CI": "1",
    "NO_COLOR": "1",
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
}

blocked = {signal.SIGTERM, signal.SIGINT}
owned = []
cleanup_started = False
received_signal = None
received_signal_number = None
spawn_error = None
timed_out = False
finalizing = False


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
    if finalizing:
        return
    raise RunnerSignal(received_signal)


def spawn():
    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
    stdout_handle = (OUT / "fixture-stdout").open("wb")
    stderr_handle = (OUT / "fixture-stderr").open("wb")
    try:
        process = subprocess.Popen(
            argv, cwd=archived_worker, env=env, stdout=stdout_handle, stderr=stderr_handle,
            start_new_session=True,
            preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, old_mask),
        )
        record = {"label": "public-buffer-fixture", "pid": process.pid, "pgid": process.pid,
                  "term_sent": False, "kill_sent": False, "leader_exit": None,
                  "group_absent": False, "forced_cleanup_hold": False, "process": process,
                  "_handles": (stdout_handle, stderr_handle)}
        owned.append(record)
        return record
    except BaseException:
        stdout_handle.close()
        stderr_handle.close()
        raise
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
                for handle in record.pop("_handles", ()):
                    handle.close()
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)


def summarize(result_path):
    try:
        result = json.loads(result_path.read_text())
    except (OSError, ValueError):
        return {"total": 0, "passed": 0, "failed": 1, "pending": 0, "assertions": [], "raw": None}
    assertions = []
    for suite in result.get("testResults", []) if isinstance(result, dict) else []:
        for assertion in suite.get("assertionResults", []):
            assertions.append({"full_name": assertion.get("fullName", ""), "status": assertion.get("status", "")})
    return {
        "total": int(result.get("numTotalTests", 0)),
        "passed": int(result.get("numPassedTests", 0)),
        "failed": int(result.get("numFailedTests", 0)),
        "pending": int(result.get("numPendingTests", 0)),
        "assertions": assertions,
        "raw": result,
    }


signal.signal(signal.SIGTERM, on_signal)
signal.signal(signal.SIGINT, on_signal)
record = None
native_rc = None
try:
    record = spawn()
    try:
        record["process"].wait(timeout=NATIVE_TIMEOUT)
    except subprocess.TimeoutExpired:
        timed_out = True
        stop(record)
    native_rc = record["process"].poll()
except RunnerSignal:
    pass
except BaseException as error:
    spawn_error = repr(error)
finally:
    finalizing = True
    cleanup()
    for path in (OUT / "fixture-stdout", OUT / "fixture-stderr"):
        path.touch(exist_ok=True)
    runtime_post = sorted(path for path in PROVIDER_DEPS.rglob("*") if path.is_file())
    post = manifest(runtime_post)
    (OUT / "post-sha256.json").write_text(json.dumps(post, indent=2, sort_keys=True) + "\n")
    input_equal = post == pre
    (OUT / "input-equality.json").write_text(json.dumps({"equal": input_equal}) + "\n")
    runtime_pre_names = set(pre["runtime"])
    runtime_post_names = set(post["runtime"])
    (OUT / "runtime-membership.json").write_text(json.dumps({
        "pre_count": len(runtime_pre_names), "post_count": len(runtime_post_names),
        "added": sorted(runtime_post_names - runtime_pre_names),
        "removed": sorted(runtime_pre_names - runtime_post_names),
        "hashes_equal": pre["runtime"] == post["runtime"],
    }, indent=2, sort_keys=True) + "\n")
    summary = summarize(test_result)
    stderr = (OUT / "fixture-stderr").read_text(errors="replace")
    diagnostic_count = stderr.count(FORBIDDEN_STDERR)
    assertions_ok = (
        summary["total"] == 1 and summary["passed"] == 1 and summary["failed"] == 0 and
        summary["pending"] == 0 and
        summary["assertions"] == [{"full_name": FIXTURE_FULL_NAME, "status": "passed"}]
    )
    clean_records = [{key: value for key, value in item.items() if key != "process"} for item in owned]
    reasons = []
    verdict = 0
    if received_signal is not None:
        verdict, reasons = 128 + int(received_signal_number), [f"runner received {received_signal}"]
    if native_rc != 0:
        verdict, reasons = native_rc if native_rc is not None else 125, reasons + ["Vitest returned nonzero"]
    if timed_out:
        verdict, reasons = 124, reasons + ["Vitest timed out"]
    if spawn_error is not None:
        verdict, reasons = 125, reasons + ["runner exception: " + spawn_error]
    if diagnostic_count:
        verdict, reasons = 125, reasons + [f"forbidden request-stream diagnostic count={diagnostic_count}"]
    if not assertions_ok:
        verdict, reasons = 125, reasons + ["test JSON is not exactly one passed expected assertion"]
    if not input_equal:
        verdict, reasons = 125, reasons + ["source/runtime input hash mismatch"]
    if (
        len(clean_records) != 1 or
        any(
            not item.get("group_absent") or item.get("forced_cleanup_hold") or
            item.get("kill_sent") or "cleanup_error" in item
            for item in clean_records
        )
    ):
        verdict, reasons = 125, reasons + ["owned process cleanup not proven"]
    (OUT / "native-exit.json").write_text(json.dumps({
        "native_rc": native_rc, "summary": summary, "assertions_ok": assertions_ok,
        "stderr_diagnostic_count": diagnostic_count, "timed_out": timed_out,
        "owned": clean_records, "received_signal": received_signal,
    }, indent=2, sort_keys=True) + "\n")
    (OUT / "process-groups.json").write_text(json.dumps({
        "groups": clean_records, "cleanup_finally": True,
        "term_grace_seconds": TERM_GRACE, "kill_grace_seconds": KILL_GRACE,
    }, indent=2, sort_keys=True) + "\n")
    (OUT / "verdict.json").write_text(json.dumps({
        "native_rc": native_rc, "verdict_rc": verdict, "reasons": reasons,
        "expected_total": 1, "expected_full_name": FIXTURE_FULL_NAME,
    }, indent=2, sort_keys=True) + "\n")
    (OUT / "native.rc").write_text("absent\n" if native_rc is None else f"{native_rc}\n")
    (OUT / "verdict.rc").write_text(f"{verdict}\n")

raise SystemExit(verdict)
