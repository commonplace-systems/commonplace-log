#!/usr/bin/env python3
"""Bounded focused Vitest workers-pool runner; native execution is root-owned."""

import hashlib
import json
import os
import pathlib
import signal
import subprocess
import sys
import tarfile
import io
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]
OUT = pathlib.Path(sys.argv[1]).resolve()
SOURCE_COMMIT = "474cf369c175dc7f9685cbb22f901d25278879ce"
FIXTURE_COMMIT = "cc8afaac0f84fde21a621e37300cf0cb755d47ca"
FIXTURE_REL = "worker/test/realm/allocation_registry.workers.test.ts"
FIXTURE_SHA = "d0a499d49e78f109f4e5af224537405d86a4f23aec081e5a204f92cd5f9a1bc0"
PROVIDER_DEPS = pathlib.Path("/home/jes/commonplace-log/worker/node_modules")
NODE = pathlib.Path("/usr/bin/node")
VITEST = PROVIDER_DEPS / "vitest/vitest.mjs"
RUNTIME_COUNT = 3221
TEST_FILES = (
    "worker/test/realm/read_capability.workers.test.ts",
    "worker/test/realm/registry.workers.test.ts",
    "worker/test/realm/realm_remove.workers.test.ts",
    "worker/test/realm/delete_all.workers.test.ts",
    "worker/test/realm/ingress.workers.test.ts",
    FIXTURE_REL,
)
EXPECTED_CASES = {
    "STORE-3b read capability > R1: every WRITE route refuses the read capability and admits the write secret",
    "STORE-3b read capability > R2: the read capability reaches every READ route, and cannot reach the mint route",
    "STORE-3b read capability > R3: mint is single-use until revoked, and a revoked capability stops authorising",
    "STORE-3b read capability > R4: a realm that EXISTED before the column can still authorise, and can be minted for",
    "STORE-3b read capability > R5: /frontier + /tail-local are reachable with the read capability alone",
    "STORE-3b read capability > an absent realm is not_found, and a wrong secret is unauthorized",
    "STORE-3b R6: every lane reaches the scope check > each lane has exactly one fetch entry and it delegates to handlePublicRealmRequest",
    "STORE-3b R6: every lane reaches the scope check > CONTROL: the recogniser can fail - a lane whose fetch bypasses the check is rejected",
    "BACKUP-1b-i realm registry > I1: create registers the realm, and the stored value is a WORKING read capability",
    "BACKUP-1b-i realm registry > I2: the capability is NEVER returned over the wire",
    "BACKUP-1b-i realm registry > I3: an unbound registry REFUSES, and creates nothing",
    "BACKUP-1b-i realm registry > I3b: the development lever admits the unbound registry, and says so by name",
    "BACKUP-1b-i realm registry > I4: a registry write failure is NAMED, and the realm remains reachable",
    "BACKUP-1b-i realm registry > I5 CONTROL, THE RED: a realm created by ANOTHER PATH leaves the registry short",
    "REALM-REMOVE-1b > R1: gateway create and entry write, positive frontier, removal, same-capability not_found",
    "REALM-REMOVE-1b > R2: reachable WRITE deletion refuses a read capability without removing its realm",
    "REALM-REMOVE-1b > R3: repeat and never-created canonical removals are empty 204s",
    "REALM-REMOVE-1b > R4: registry failure is named after real wipe; an unauthenticated retry RETAINS the KV row",
    "REALM-REMOVE-1b > R4 storage failure never drops the registry row or live realm",
    "REALM-REMOVE-1b > R5: real KV inventory loses exactly the removed realm and ignores spoofed identity",
    "REALM-REMOVE-1b > removal keeps wrong/missing bearer, READ scope, root-only and revocation boundaries",
    "REALM-REMOVE-1b > both lane dispatchers gate creation and removal through native blockConcurrencyWhile only",
    "REALM-REMOVE-1b > unbound registry defaults to refusal before wiping a live realm",
    "REALM-REMOVE-1a: does deleteAll() drop SQL, not just key-value? > D1 removes the realm: a write capability that authorised before reads not_found after",
    "REALM-REMOVE-1a: does deleteAll() drop SQL, not just key-value? > D2 drops the SQL TABLE itself, not merely its rows",
    "REALM-REMOVE-1a: does deleteAll() drop SQL, not just key-value? > D3 is not a mock: the same object is usable again afterwards, so removal is not corruption",
    "realm ingress > serves GET / unauthenticated",
    "realm ingress > creates once with and without a location hint and returns the secret only once",
    "realm ingress > rejects invalid create bodies and location hints with 400",
    "realm ingress > requires the deployment token for create",
    "realm ingress > returns not_found for sidecar, engine, and node paths of an uncreated realm",
    "realm ingress > lets only the created realm's secret reach its routes",
    "realm ingress > keeps two realm secrets scoped, with positive controls both ways",
    "realm ingress > requires a syntactically valid bearer on realm routes",
    "realm ingress > returns 404 for malformed realm ids and unknown top-level paths",
    "realm ingress > needs GATEWAY_TOKEN only for create, not for an authorized realm route",
    "realm ingress > passes a validated location hint to idFromName plus get for create",
    "deployed-base allocation and registry > registers a usable capability, rejects stale registry data, and makes an exact retry KV-idempotent",
    "deployed-base allocation and registry > refuses an unbound registry before SQL mutation even when the unsafe lever is supplied",
    "deployed-base allocation and registry > names a KV write failure as pending work and recovers the same allocation on retry",
    "deployed-base allocation and registry > does not restore a revoked read hash on an allocation retry",
    "deployed-base allocation and registry > uses the real gateway and KV registry: 201 then 200, frontier 200, restore 403",
    "deployed-base allocation and registry > requires the deployment bearer and never treats a read capability as allocation authority",
}
EXPECTED_RESULT_COUNT = 43
CHILD_TIMEOUT = 150
TERM_GRACE = 5
KILL_GRACE = 2
EXTERNAL_OUTER = 210
EXTERNAL_CLEANUP = 30

if OUT.exists():
    raise SystemExit(f"refusing existing output: {OUT}")
if len(EXPECTED_CASES) != EXPECTED_RESULT_COUNT or len(TEST_FILES) != 6:
    raise SystemExit("frozen workers-pool case manifest is internally inconsistent")
if not PROVIDER_DEPS.is_dir() or not VITEST.is_file() or not NODE.is_file():
    raise SystemExit("installed worker runtime is unavailable")
if len([p for p in PROVIDER_DEPS.rglob("*") if p.is_file()]) != RUNTIME_COUNT:
    raise SystemExit("worker runtime membership count mismatch")
if subprocess.run(["git", "-C", str(ROOT), "cat-file", "-t", SOURCE_COMMIT]).returncode != 0:
    raise SystemExit("provider source commit is unavailable")
if subprocess.run(["git", "-C", str(ROOT), "cat-file", "-t", FIXTURE_COMMIT]).returncode != 0:
    raise SystemExit("fixture commit is unavailable")
fixture_bytes = subprocess.check_output(["git", "-C", str(ROOT), "show", f"{FIXTURE_COMMIT}:{FIXTURE_REL}"])
if hashlib.sha256(fixture_bytes).hexdigest() != FIXTURE_SHA:
    raise SystemExit("fixture commit SHA mismatch")
if subprocess.run(["git", "-C", str(ROOT), "diff", "--quiet", SOURCE_COMMIT, "HEAD", "--", "worker/src", "worker/package.json", "worker/package-lock.json", "worker/vitest.workers.config.ts", "worker/wrangler.test.jsonc"]).returncode != 0:
    raise SystemExit("provider product source differs from frozen source")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_files(path):
    return sorted(p for p in path.rglob("*") if p.is_file())


OUT.mkdir(parents=True)
context = OUT / "context"
context.mkdir()
archive = subprocess.check_output(["git", "-C", str(ROOT), "archive", SOURCE_COMMIT, "worker/src", "worker/test/realm", "worker/package.json", "worker/package-lock.json", "worker/vitest.workers.config.ts", "worker/wrangler.test.jsonc", "worker/tsconfig.workers.json"])
with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as tar:
    tar.extractall(context)
fixture = context / FIXTURE_REL
fixture.parent.mkdir(parents=True, exist_ok=True)
fixture.write_bytes(fixture_bytes)
config = context / "worker/wrangler.test.jsonc"
config_text = config.read_text()
if "REALM_REGISTRY" not in config_text or "REALM_CONTAINER" not in config_text:
    raise SystemExit("generated workers config lacks REALM_REGISTRY or REALM_CONTAINER")
root_cache_dir = OUT / "root-cache"
worker_cache_dir = OUT / "worker-cache"
runner_config = context / "worker/vitest.workers.runner.config.ts"
runner_config.write_text(
    'import { mergeConfig } from "vitest/config";\n'
    'import base from "./vitest.workers.config.ts";\n'
    f'export default mergeConfig(base, {{ cacheDir: {json.dumps(str(root_cache_dir))}, '
    f'test: {{ cache: {{ dir: {json.dumps(str(worker_cache_dir))} }} }} }});\n'
)
node_modules = context / "worker/node_modules"
node_modules.symlink_to(PROVIDER_DEPS)

selected = [str(pathlib.Path(rel).relative_to("worker")) for rel in TEST_FILES]
vitest_cmd = [str(NODE), str(VITEST), "run", "--config", str(runner_config), "--reporter=json", "--outputFile", str(OUT / "vitest-results.json"), "--bail=1", *selected]
files = {}


def add(label, path):
    if not path.is_file():
        raise SystemExit(f"missing packet input: {path}")
    if label in files:
        raise SystemExit(f"duplicate packet input: {label}")
    files[label] = path


for path in source_files(context):
    add(f"context/{path.relative_to(context)}", path)
for path in (pathlib.Path(__file__), runner_config):
    add(f"runner/{path.name}", path)
for path in source_files(PROVIDER_DEPS):
    add(f"worker-runtime/{path.relative_to(PROVIDER_DEPS)}", path)
for label, path in (("tool/node", NODE), ("tool/vitest", VITEST)):
    add(label, path)
pre = {label: sha256(path) for label, path in sorted(files.items())}
(OUT / "input-sha256.json").write_text(json.dumps(pre, indent=2, sort_keys=True) + "\n")
(OUT / "source-pins.json").write_text(json.dumps({
    "provider_root": str(ROOT),
    "source_commit": SOURCE_COMMIT,
    "fixture_commit": FIXTURE_COMMIT,
    "fixture_path": FIXTURE_REL,
    "fixture_sha256": FIXTURE_SHA,
    "selected_files": TEST_FILES,
    "expected_case_count": EXPECTED_RESULT_COUNT,
    "runtime_root": str(PROVIDER_DEPS),
    "runtime_file_count": RUNTIME_COUNT,
    "registry_binding": "REALM_REGISTRY",
    "realm_binding": "REALM_CONTAINER",
}, indent=2, sort_keys=True) + "\n")
(OUT / "command.json").write_text(json.dumps({
    "argv": vitest_cmd,
    "cwd": str(context / "worker"),
    "selected_files": selected,
    "child_timeout_seconds": CHILD_TIMEOUT,
    "external_outer_seconds": EXTERNAL_OUTER,
    "external_cleanup_seconds": EXTERNAL_CLEANUP,
    "term_grace_seconds": TERM_GRACE,
    "kill_grace_seconds": KILL_GRACE,
    "root_cache_dir": str(root_cache_dir),
    "worker_cache_dir": str(worker_cache_dir),
}, indent=2, sort_keys=True) + "\n")

env = {
    "PATH": "/usr/bin:/bin",
    "HOME": str(OUT / "home"),
    "TMPDIR": str(OUT / "tmp"),
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "CI": "1",
    "NO_COLOR": "1",
    "CLOUDFLARE_LOAD_DEV_VARS_FROM_DOT_ENV": "false",
}
for name in ("home", "tmp"):
    (OUT / name).mkdir()
owned = []
signal_received = None
finalizing = False
cleanup_started = False


class RunnerInterrupted(Exception):
    pass


def on_signal(signum, _frame):
    global signal_received
    if signal_received is None:
        signal_received = signal.Signals(signum).name
    if not finalizing:
        raise RunnerInterrupted(signal_received)


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


def cleanup():
    global cleanup_started
    if cleanup_started:
        return
    cleanup_started = True
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT})
    try:
        for record in reversed(owned):
            try:
                stop(record)
            except BaseException as error:
                record["cleanup_error"] = repr(error)
                record["forced_cleanup_hold"] = True
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


for signum in (signal.SIGTERM, signal.SIGINT):
    signal.signal(signum, on_signal)
record = None
timed_out = False
spawn_error = None
try:
    with (OUT / "stdout").open("wb") as stdout, (OUT / "stderr").open("wb") as stderr:
        try:
            previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT})
            try:
                process = subprocess.Popen(
                    vitest_cmd,
                    cwd=context / "worker",
                    env=env,
                    stdout=stdout,
                    stderr=stderr,
                    start_new_session=True,
                    preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, previous),
                )
                record = {"label": "vitest", "pid": process.pid, "pgid": process.pid, "process": process, "term_sent": False, "kill_sent": False}
                owned.append(record)
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, previous)
            try:
                process.wait(timeout=CHILD_TIMEOUT)
            except subprocess.TimeoutExpired:
                timed_out = True
                stop(record)
        except RunnerInterrupted:
            raise
        except BaseException as error:
            spawn_error = repr(error)
except RunnerInterrupted:
    pass
except BaseException as error:
    spawn_error = spawn_error or repr(error)
finally:
    finalizing = True
    cleanup()
    for path in (OUT / "stdout", OUT / "stderr"):
        path.touch(exist_ok=True)
    post_runtime = [path for path in PROVIDER_DEPS.rglob("*") if path.is_file()]
    post_runtime_names = sorted(str(path.relative_to(PROVIDER_DEPS)) for path in post_runtime)
    pre_runtime_names = sorted(label.removeprefix("worker-runtime/") for label in pre if label.startswith("worker-runtime/"))
    additions = sorted(set(post_runtime_names) - set(pre_runtime_names))
    removals = sorted(set(pre_runtime_names) - set(post_runtime_names))
    (OUT / "runtime-inventory.json").write_text(json.dumps({"pre_count": len(pre_runtime_names), "post_count": len(post_runtime_names), "added": additions, "removed": removals}, indent=2, sort_keys=True) + "\n")
    post_error = None
    try:
        post = {label: sha256(path) for label, path in sorted(files.items())}
    except BaseException as error:
        post = {}
        post_error = repr(error)
    equal = post_error is None and pre == post
    (OUT / "input-sha256-post.json").write_text(json.dumps(post, indent=2, sort_keys=True) + "\n")
    (OUT / "input-equality.json").write_text(json.dumps({"equal": equal, "input_count": len(pre)}) + "\n")
    result_data = None
    try:
        result_data = json.loads((OUT / "vitest-results.json").read_text())
    except (OSError, json.JSONDecodeError):
        pass
    assertions = []
    def collect(value):
        if isinstance(value, dict):
            if isinstance(value.get("fullName"), str) and isinstance(value.get("status"), str):
                assertions.append({"fullName": value["fullName"], "status": value["status"]})
            for child in value.values():
                collect(child)
        elif isinstance(value, list):
            for child in value:
                collect(child)
    collect(result_data)
    observed_names = {item["fullName"] for item in assertions}
    result_ok = len(assertions) == EXPECTED_RESULT_COUNT and observed_names == EXPECTED_CASES and all(item["status"] == "passed" for item in assertions)
    stream_lines = [line for path in (OUT / "stdout", OUT / "stderr") for line in path.read_text(errors="replace").splitlines() if "request stream" in line.lower() or "stream error" in line.lower()]
    native_rc = None if record is None else record["process"].poll()
    reasons = []
    if native_rc != 0: reasons.append("Vitest child rc is not zero")
    if timed_out: reasons.append("Vitest child timed out")
    if spawn_error: reasons.append("Vitest spawn failed")
    if not result_ok: reasons.append("selected assertion full-name/status manifest is not exact")
    if not equal: reasons.append("input PRE/POST manifest mismatch")
    if post_error: reasons.append("POST input hashing failed")
    if additions or removals: reasons.append("worker runtime membership changed")
    if stream_lines: reasons.append("unexpected stream diagnostics")
    if signal_received: reasons.append("runner received a signal")
    if len(owned) != 1 or any(item.get("forced_cleanup_hold") or not item.get("group_absent") for item in owned): reasons.append("owned process cleanup not proven")
    verdict = 0 if not reasons else 125
    records = [{key: value for key, value in item.items() if key != "process"} for item in owned]
    (OUT / "native.rc").write_text(json.dumps({"native_rc": native_rc, "result_ok": result_ok, "stream_diagnostic_count": len(stream_lines), "timed_out": timed_out}) + "\n")
    (OUT / "process-groups.json").write_text(json.dumps({"groups": records, "first_signal_received": signal_received, "cleanup_in_finally": True, "term_grace_seconds": TERM_GRACE, "kill_grace_seconds": KILL_GRACE}, indent=2, sort_keys=True) + "\n")
    (OUT / "verdict.json").write_text(json.dumps({"native_rc": native_rc, "verdict_rc": verdict, "reasons": reasons, "assertions": assertions, "expected_case_count": EXPECTED_RESULT_COUNT}, indent=2, sort_keys=True) + "\n")
    (OUT / "verdict.rc").write_text(f"{verdict}\n")
raise SystemExit(verdict)
