#!/usr/bin/env python3
"""Bounded one-arm ingress body-ownership observation runner; native owner runs it."""
import hashlib
import io
import json
import os
import pathlib
import re
import signal
import socket
import subprocess
import sys
import tarfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]
APP_ROOT = pathlib.Path("/home/jes/commonplace-next-restore-public-operation")
APP_OUTPUT = APP_ROOT / "tmp/restore-public-operation-1"
OUT = pathlib.Path(sys.argv[1]).resolve()
PROVIDER_COMMIT = "6213d4498354861c6e3a5ff8a047b93ce380304e"
PROVIDER_CONFIG_REL = "worker/wrangler.test.jsonc"
PROVIDER_DEPS = pathlib.Path("/home/jes/commonplace-log/worker/node_modules")
BEAM_ROOT = pathlib.Path(os.environ.get("RESTORE_PUBLIC_AUTH_BEAM_ROOT", "/home/jes/codex-save-state-1/tmp/origin-receipt-1/_build/test/lib"))
ELIXIR = pathlib.Path(os.environ.get("RESTORE_PUBLIC_AUTH_ELIXIR", "/home/jes/.asdf/installs/elixir/1.18.4-otp-27/bin/elixir"))
ERLANG_BIN = "/home/jes/.asdf/installs/erlang/27.3.4.8/bin"
FIXTURE_COMMIT = "c9011535742daea9ecb216185e54ed41a3d470af"
FIXTURE_REL = "test/commonplace_next/backup/restore_public_auth_diagnostic_test.exs"
FIXTURE_SHA = "74ec70076df0a9e9058034234fd6951a110ddf65632b1d416c7fdd672327126f"
EXPECTED_CASE = "test rejects a body-bearing wrong secret before returning the unchanged empty inventory"
CLIENT_COMMIT = "54bb61913b893b120d1fed052ca4c69f199ea899"
CLIENT_SOURCE_SHA = "2b653ce570cfe72d79c6c964eafb1a7b7b10874a70f45b602f5de0f54207613d"
RETAINED_APP_EBIN = APP_OUTPUT / "restore-public-operation-app-ebin"
RETAINED_DEP_EBIN = APP_OUTPUT / "restore-public-operation-dependency-ebin"
RETAINED_CLIENT_SOURCE = APP_OUTPUT / "client-source-cloudflare-sidecar.ex"
RETAINED_MANIFEST = APP_ROOT / "docs/measurements/restore-public-operation-1/output-manifest-1.json"
SCRIPT = pathlib.Path(__file__).with_name("restore_public_auth_diagnostic.exs")
RUNNER = pathlib.Path(__file__)
CACHED_BEAMS = 847
WORKER_RUNTIME = 3221
START_TIMEOUT = 30
TEST_TIMEOUT = 30
OUTER_TIMEOUT = 180
TERM_GRACE = 5
KILL_GRACE = 2
DIAGNOSTIC = "Uncaught TypeError: Can't read from request stream after response has been sent."
TRACE_PREFIX = "[restore-http-body-diagnostic] "
TRACE_RE = re.compile(r"\[restore-http-body-diagnostic\] (beforeforward|afterstubresponse) (.*)$")
KV_RE = re.compile(r"(category|status|original_used|original_locked|forwarded_used|forwarded_locked|cancel)=([^ ]+)")
EXPECTED_PHASES = [("create", 201), ("realm", 200), ("realm", 401), ("realm", 200)]

if OUT.exists():
    raise SystemExit(f"refusing existing output: {OUT}")
OUT.mkdir(parents=True)


def git(path, *args):
    return subprocess.check_output(["git", "-C", str(path), *args], text=True).strip()


def git_bytes(path, revision, rel):
    return subprocess.check_output(["git", "-C", str(path), "show", f"{revision}:{rel}"])


def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def source_files(path):
    return [path] if path.is_file() else sorted(p for p in path.rglob("*") if p.is_file())


def add(files, label, path):
    if not path.is_file():
        raise SystemExit(f"missing input: {path}")
    if label in files:
        raise SystemExit(f"duplicate input: {label}")
    files[label] = path


def materialize_context():
    context = OUT / "context"
    context.mkdir()
    archive = subprocess.check_output(["git", "-C", str(ROOT), "archive", PROVIDER_COMMIT, "worker/src", "worker/package.json", "worker/package-lock.json"])
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as tar:
        tar.extractall(context)
    worker = context / "worker"
    config = json.loads(git_bytes(ROOT, PROVIDER_COMMIT, PROVIDER_CONFIG_REL))
    config["vars"] = {"GATEWAY_TOKEN": "test-gateway-token"}
    config["name"] = "commonplace-log-auth-body-diagnostic"
    config_path = worker / "wrangler.restore-public-auth-diagnostic.jsonc"
    config_path.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n")
    node_modules = worker / "node_modules"
    if node_modules.exists() or node_modules.is_symlink():
        raise SystemExit("provider context has an unexpected node_modules entry")
    node_modules.symlink_to(PROVIDER_DEPS)
    return context, config_path


if git(ROOT, "cat-file", "-t", PROVIDER_COMMIT) != "commit":
    raise SystemExit("diagnostic provider commit unavailable")
if git(APP_ROOT, "cat-file", "-t", FIXTURE_COMMIT) != "commit":
    raise SystemExit("fixture commit unavailable")
fixture_current = APP_ROOT / FIXTURE_REL
if sha256(fixture_current) != FIXTURE_SHA:
    raise SystemExit("current fixture does not match frozen SHA")
if sha256(RETAINED_CLIENT_SOURCE) != CLIENT_SOURCE_SHA:
    raise SystemExit("retained client source provenance mismatch")
if not RETAINED_MANIFEST.is_file() or not RETAINED_APP_EBIN.is_dir() or not RETAINED_DEP_EBIN.is_dir():
    raise SystemExit("accepted public-operation receipt/eBins unavailable")
if len(list(BEAM_ROOT.rglob("*.beam"))) != CACHED_BEAMS:
    raise SystemExit("cached BEAM count mismatch")
if len(source_files(PROVIDER_DEPS)) != WORKER_RUNTIME:
    raise SystemExit("worker runtime count mismatch")

fixture = OUT / "fixture" / pathlib.Path(FIXTURE_REL).name
fixture.parent.mkdir(parents=True)
fixture.write_bytes(git_bytes(APP_ROOT, FIXTURE_COMMIT, FIXTURE_REL))
if sha256(fixture) != FIXTURE_SHA:
    raise SystemExit("materialized fixture SHA mismatch")
context, config_path = materialize_context()

retained_manifest = json.loads(RETAINED_MANIFEST.read_text())
retained_hashes = {item["path"]: item["sha256"] for item in retained_manifest["files"]}
files = {}
for p in source_files(context):
    add(files, f"provider-context/{p.relative_to(context)}", p)
add(files, "fixture/frozen-test.exs", fixture)
add(files, "runner/restore_public_auth_diagnostic.exs", SCRIPT)
add(files, "runner/run_restore_public_auth_diagnostic.py", RUNNER)
add(files, "retained/output-manifest-1.json", RETAINED_MANIFEST)
add(files, "retained/client-source-cloudflare-sidecar.ex", RETAINED_CLIENT_SOURCE)
for root, prefix in ((RETAINED_APP_EBIN, "retained-app-ebin"), (RETAINED_DEP_EBIN, "retained-dependency-ebin")):
    for p in source_files(root):
        rel = str(p.relative_to(APP_OUTPUT))
        if retained_hashes.get(rel) != sha256(p):
            raise SystemExit(f"retained BEAM differs from accepted manifest: {rel}")
        add(files, f"{prefix}/{p.relative_to(root)}", p)
for p in sorted(BEAM_ROOT.rglob("*.beam")):
    add(files, f"cached-beam/{p.relative_to(BEAM_ROOT)}", p)
for p in sorted(source_files(PROVIDER_DEPS)):
    add(files, f"worker-runtime/{p.relative_to(PROVIDER_DEPS)}", p)
TOOL_PATHS = {"node": pathlib.Path("/usr/bin/node"), "elixir": ELIXIR, "erl": pathlib.Path(ERLANG_BIN) / "erl", "erlc": pathlib.Path(ERLANG_BIN) / "erlc"}
for name, p in TOOL_PATHS.items():
    add(files, f"tool/{name}", p)

runtime_pre_paths = sorted(p for p in PROVIDER_DEPS.rglob("*") if p.is_file())
runtime_pre_names = [str(p.relative_to(PROVIDER_DEPS)) for p in runtime_pre_paths]
pre = {label: sha256(p) for label, p in sorted(files.items())}
(OUT / "input-sha256.json").write_text(json.dumps(pre, indent=2, sort_keys=True) + "\n")

port_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
port_socket.bind(("127.0.0.1", 0))
port = port_socket.getsockname()[1]
port_socket.close()
worker = context / "worker"
wrangler = PROVIDER_DEPS / "wrangler/bin/wrangler.js"
wrangler_cmd = ["/usr/bin/node", str(wrangler), "dev", "--local", "--env-file=/dev/null", "--config", str(config_path), "--ip", "127.0.0.1", "--port", str(port), "--persist-to", str(OUT / "state")]
(OUT / "command.json").write_text(json.dumps({"provider_commit": PROVIDER_COMMIT, "fixture_commit": FIXTURE_COMMIT, "wrangler_argv": wrangler_cmd, "driver_argv": [str(ELIXIR), str(SCRIPT), str(OUT)], "base_url": f"http://127.0.0.1:{port}", "limits": {"start_seconds": START_TIMEOUT, "test_seconds": TEST_TIMEOUT, "outer_seconds": OUTER_TIMEOUT, "term_seconds": TERM_GRACE, "kill_seconds": KILL_GRACE}, "startup": {"otp_apps": ["crypto", "inets", "ssl"], "commonplace_next": False}}, indent=2, sort_keys=True) + "\n")
(OUT / "source-pins.json").write_text(json.dumps({"provider_commit": PROVIDER_COMMIT, "provider_repo": str(ROOT), "provider_config": PROVIDER_CONFIG_REL, "fixture_commit": FIXTURE_COMMIT, "fixture_sha256": FIXTURE_SHA, "test_file": FIXTURE_REL, "expected_case": EXPECTED_CASE, "client_commit": CLIENT_COMMIT, "client_source_sha256": CLIENT_SOURCE_SHA, "retained_output_manifest": str(RETAINED_MANIFEST), "retained_output_manifest_sha256": sha256(RETAINED_MANIFEST), "retained_app_ebin": str(RETAINED_APP_EBIN), "retained_dependency_ebin": str(RETAINED_DEP_EBIN), "cached_beam_root": str(BEAM_ROOT), "cached_beam_count": CACHED_BEAMS, "worker_runtime_root": str(PROVIDER_DEPS), "worker_runtime_file_count": WORKER_RUNTIME, "instrumentation": "safe body-state phase traces only; no body or credential values"}, indent=2, sort_keys=True) + "\n")

owned = []
first_signal = None
finalizing = False
cleanup_done = False
class FirstSignal(Exception): pass


def group_exists(pgid):
    try:
        os.killpg(pgid, 0); return True
    except ProcessLookupError: return False
    except PermissionError: return True


def stop(record):
    process, pgid = record["process"], record["pgid"]
    if not group_exists(pgid):
        record["leader_exit"] = process.poll(); record["group_absent"] = True; return
    try: os.killpg(pgid, signal.SIGTERM); record["term_sent"] = True
    except ProcessLookupError: pass
    deadline = time.monotonic() + TERM_GRACE
    while group_exists(pgid) and time.monotonic() < deadline:
        process.poll(); time.sleep(0.05)
    if group_exists(pgid):
        try: os.killpg(pgid, signal.SIGKILL); record["kill_sent"] = True
        except ProcessLookupError: pass
        deadline = time.monotonic() + KILL_GRACE
        while group_exists(pgid) and time.monotonic() < deadline:
            process.poll(); time.sleep(0.05)
    record["leader_exit"] = process.poll(); record["group_absent"] = not group_exists(pgid)
    record["forced_cleanup_hold"] = bool(record["kill_sent"] or not record["group_absent"])


def on_signal(signum, _frame):
    global first_signal
    if first_signal is None: first_signal = signum
    if not finalizing: raise FirstSignal(signum)


def spawn(label, argv, cwd, env, stdout, stderr):
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT})
    try:
        if first_signal is not None or finalizing: raise FirstSignal(first_signal or signal.SIGTERM)
        process = subprocess.Popen(argv, cwd=cwd, env=env, stdout=stdout, stderr=stderr, start_new_session=True, preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, previous))
        record = {"label": label, "pid": process.pid, "pgid": process.pid, "process": process, "term_sent": False, "kill_sent": False, "leader_exit": None, "group_absent": False, "forced_cleanup_hold": False}
        owned.append(record)
        return record
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def env_for(arm_out):
    return {"PATH": ERLANG_BIN + os.pathsep + "/usr/bin:/bin", "HOME": str(arm_out / "home"), "XDG_CONFIG_HOME": str(arm_out / "config"), "TMPDIR": str(arm_out / "tmp"), "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "ERL_FLAGS": "+S 2:2", "WRANGLER_SEND_METRICS": "false", "CLOUDFLARE_LOAD_DEV_VARS_FROM_DOT_ENV": "false", "CI": "1", "NO_COLOR": "1", "RESTORE_PUBLIC_AUTH_OUT": str(arm_out), "RESTORE_PUBLIC_AUTH_TEST_FILE": str(fixture), "RESTORE_PUBLIC_AUTH_APP_EBIN": str(RETAINED_APP_EBIN), "RESTORE_PUBLIC_AUTH_DEP_EBIN": str(RETAINED_DEP_EBIN), "RESTORE_PUBLIC_AUTH_BEAM_ROOT": str(BEAM_ROOT), "RESTORE_PUBLIC_AUTH_EXPECTED_CASE": EXPECTED_CASE, "RESTORE_PROVIDER_HTTP_BASE_URL": f"http://127.0.0.1:{port}"}


def ready(record):
    deadline = time.monotonic() + START_TIMEOUT
    while time.monotonic() < deadline:
        if record["process"].poll() is not None: return False
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2): return True
        except OSError: time.sleep(0.1)
    return False


previous_handlers = (signal.getsignal(signal.SIGTERM), signal.getsignal(signal.SIGINT))
signal.signal(signal.SIGTERM, on_signal); signal.signal(signal.SIGINT, on_signal)
arm_out = OUT
for name in ("home", "config", "tmp", "state"):
    (arm_out / name).mkdir(parents=True)
ready_ok = False
fixture_record = None
wrangler_record = None
arm_error = None
started = time.monotonic()
try:
    wsout = (OUT / "wrangler-stdout").open("wb"); wserr = (OUT / "wrangler-stderr").open("wb")
    try:
        wrangler_record = spawn("wrangler", wrangler_cmd, worker, env_for(OUT), wsout, wserr)
        ready_ok = ready(wrangler_record)
        (OUT / "readiness.json").write_text(json.dumps({"ready": ready_ok, "port": port}) + "\n")
        if not ready_ok: raise RuntimeError("Wrangler did not become ready")
        sout = (OUT / "stdout").open("wb"); serr = (OUT / "stderr").open("wb")
        try:
            fixture_record = spawn("fixture", [str(ELIXIR), str(SCRIPT), str(OUT)], ROOT, env_for(OUT), sout, serr)
            try:
                fixture_record["process"].wait(timeout=TEST_TIMEOUT)
            except subprocess.TimeoutExpired:
                fixture_record["timeout"] = True
                stop(fixture_record)
        finally:
            sout.close(); serr.close()
        if fixture_record.get("timeout"): raise RuntimeError("fixture timed out")
        if fixture_record["process"].poll() != 0: raise RuntimeError("fixture failed")
    except FirstSignal:
        raise
    finally:
        if fixture_record is not None: stop(fixture_record)
        if wrangler_record is not None: stop(wrangler_record)
        wsout.close(); wserr.close()
except FirstSignal:
    arm_error = "first signal received"
except BaseException as error:
    arm_error = repr(error)
finally:
    finalizing = True
    mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT})
    try:
        if not cleanup_done:
            cleanup_done = True
            for record in reversed(owned):
                try: stop(record)
                except BaseException as error: record["cleanup_error"] = repr(error); record["forced_cleanup_hold"] = True
        signal.pthread_sigmask(signal.SIG_SETMASK, mask)
        traces = []
        for stream in (OUT / "wrangler-stdout", OUT / "wrangler-stderr"):
            if not stream.is_file(): continue
            for line in stream.read_text(errors="replace").splitlines():
                match = TRACE_RE.search(line)
                if not match: continue
                phase, payload = match.groups()
                fields = dict(KV_RE.findall(payload))
                safe = {"phase": phase}
                for key in ("category", "status", "original_used", "original_locked", "forwarded_used", "forwarded_locked", "cancel"):
                    if key in fields: safe[key] = int(fields[key]) if key == "status" else (fields[key] == "true" if key.endswith("used") or key.endswith("locked") else fields[key])
                traces.append(safe)
        (OUT / "diagnostic-traces.json").write_text(json.dumps({"traces": traces, "error_count": (OUT / "wrangler-stderr").read_text(errors="replace").count(DIAGNOSTIC), "safe_fields_only": True}, indent=2, sort_keys=True) + "\n")
        before = [x for x in traces if x["phase"] == "beforeforward"]
        after = [x for x in traces if x["phase"] == "afterstubresponse"]
        phases_ok = len(before) == 4 and len(after) == 4 and [(x.get("category"), x.get("status")) for x in after] == EXPECTED_PHASES and [x.get("category") for x in before] == [x[0] for x in EXPECTED_PHASES]
        result = None
        try: result = json.loads((OUT / "app-result.json").read_text())
        except (OSError, ValueError): pass
        result_ok = bool(result and result.get("status") == "expected" and result.get("total") == 1 and result.get("failures") == 0 and result.get("excluded") == 0 and result.get("skipped") == 0 and fixture_record and fixture_record.get("process").poll() == 0)
        post = {label: sha256(path) for label, path in sorted(files.items())}
        post_runtime_paths = sorted(p for p in PROVIDER_DEPS.rglob("*") if p.is_file())
        post_names = [str(p.relative_to(PROVIDER_DEPS)) for p in post_runtime_paths]
        additions = sorted(set(post_names) - set(runtime_pre_names)); removals = sorted(set(runtime_pre_names) - set(post_names))
        input_equal = pre == post; runtime_equal = not additions and not removals and len(post_names) == len(runtime_pre_names)
        hold = any(x.get("forced_cleanup_hold") or x.get("cleanup_error") for x in owned)
        groups_ok = len(owned) == 2 and all(x.get("group_absent") and x.get("leader_exit") is not None for x in owned)
        observed_ok = result_ok and phases_ok and input_equal and runtime_equal and groups_ok and not hold and first_signal is None and not arm_error
        (OUT / "post-sha256.json").write_text(json.dumps(post, indent=2, sort_keys=True) + "\n")
        (OUT / "runtime-inventory.json").write_text(json.dumps({"root": str(PROVIDER_DEPS), "pre_count": len(runtime_pre_names), "post_count": len(post_names), "added": additions, "removed": removals}, indent=2, sort_keys=True) + "\n")
        (OUT / "input-equality.json").write_text(json.dumps({"equal": input_equal, "input_count": len(pre)}) + "\n")
        (OUT / "native.rc").write_text(json.dumps({"native_rc": 0 if observed_ok else 125, "observation_status": "observed" if observed_ok else "incomplete", "result_ok": result_ok, "phase_trace_ok": phases_ok, "error_count": (OUT / "wrangler-stderr").read_text(errors="replace").count(DIAGNOSTIC), "groups_ok": groups_ok, "input_equal": input_equal, "runtime_equal": runtime_equal, "first_signal": first_signal, "arm_error": arm_error}) + "\n")
        (OUT / "process-groups.json").write_text(json.dumps({"groups": [{k: v for k, v in x.items() if k != "process"} for x in owned], "all_absent": groups_ok, "first_signal_received": first_signal, "cleanup_in_finally": True, "finalizing_latch_active_through_verdict": True, "term_grace_seconds": TERM_GRACE, "kill_grace_seconds": KILL_GRACE}, indent=2, sort_keys=True) + "\n")
        (OUT / "verdict.rc").write_text(("0" if observed_ok else "125") + "\n")
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, mask)
        signal.signal(signal.SIGTERM, previous_handlers[0]); signal.signal(signal.SIGINT, previous_handlers[1])

raise SystemExit(int((OUT / "verdict.rc").read_text().strip()))
