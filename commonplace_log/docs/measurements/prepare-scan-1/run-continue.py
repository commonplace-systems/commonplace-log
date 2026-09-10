"""One local source validation sequence; no image builds, credentials or cloud calls."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

os.umask(0o077)
deadline = time.monotonic() + 95
active = None
interrupted = False

def interrupt(signum, _frame):
    global interrupted
    if not interrupted:
        interrupted = True
        raise InterruptedError('outer signal ' + str(signum))

signal.signal(signal.SIGTERM, interrupt)
signal.signal(signal.SIGINT, interrupt)

def stop_owned(proc, grace):
    # Called only for the currently owned, not-yet-reaped session/group.
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        return proc.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        return proc.wait(timeout=grace)

repo = Path('/home/jes/commonplace-log-prepare-scan')
app = repo / 'commonplace_log'
packet = app / 'docs/measurements/prepare-scan-1'
out = Path(sys.argv[1])
assert out.is_absolute() and out.parent == repo / 'tmp' and not out.exists() and not out.is_symlink()
expected = json.loads((packet / 'INPUTS-continue.json').read_text())

def bindings():
    actual = {p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in expected}
    assert actual == expected, 'input drift; no execution/retry'
    return actual

pre = bindings()
out.mkdir(parents=True, mode=0o700)
(out / 'inputs-PRE.json').write_text(json.dumps(pre, sort_keys=True, indent=2))
env = {'PATH': '/home/jes/.asdf/installs/erlang/27.3.4.8/bin:/usr/bin:/bin',
       'LANG': 'C.UTF-8', 'TMPDIR': str(out), 'ERL_FLAGS': '+S 2:2 +SDcpu 1 +SDio 1'}
elixir = '/home/jes/.asdf/installs/elixir/1.18.4-otp-27/bin/elixir'
beam = '/home/jes/codex-save-state-1/tmp/origin-receipt-1/_build/test/lib/*/ebin'
receipt = {'complete': False, 'children': [], 'failure': None}

def child(label, argv, cwd, seconds, expected_rc):
    global active
    assert deadline - time.monotonic() >= seconds + 6, 'insufficient child/cleanup/receipt reserve'
    with (out / (label + '.stdout')).open('wb') as stdout, (out / (label + '.stderr')).open('wb') as stderr:
        child_env = dict(env, PREPARE_SCAN_RESULTS=str(out / (label + '-metrics.json')))
        proc = subprocess.Popen(argv, cwd=cwd, env=child_env, stdin=subprocess.DEVNULL,
                                stdout=stdout, stderr=stderr, start_new_session=True)
        active = proc
        item = {'label': label, 'pid': proc.pid, 'pgid': os.getpgid(proc.pid),
                'sid': os.getsid(proc.pid), 'expected_rc': expected_rc, 'timeout': False}
        receipt['children'].append(item)
        try:
            try:
                rc = proc.wait(timeout=seconds)
            except subprocess.TimeoutExpired:
                item['timeout'] = True
                rc = stop_owned(proc, 2)
        finally:
            if proc.poll() is None:
                # The outer timeout grants five seconds after TERM.
                # Reserve part of that for reaping and receipt writing.
                try:
                    stop_owned(proc, 0.5 if interrupted else 2)
                except subprocess.TimeoutExpired:
                    item['cleanup_hold'] = 'owned child not reaped'
            item['original_rc'] = proc.returncode
            (out / (label + '.rc')).write_text(str(proc.returncode) + '\n')
            try:
                os.killpg(proc.pid, 0)
                item['group_absent'] = False
                item['cleanup_hold'] = 'owned group still present'
            except ProcessLookupError:
                item['group_absent'] = True
            if proc.returncode is not None:
                active = None
    assert item['group_absent'], 'owned process group remains; retain stop'
    assert not item['timeout'] and rc == expected_rc, 'unexpected child result; retain stop'
    for suffix in ['stdout', 'stderr']:
        assert (out / (label + '.' + suffix)).stat().st_size <= 1_048_576, 'output cap'
    return (out / (label + '.stdout')).read_text()

try:
    local = out / 'continuation'
    local.mkdir(mode=0o700)
    child('continuation', [elixir, '-pa', beam, str(packet / 'check-continue.exs'), str(local), 'continuation'], app, 75, 0)
    result = json.loads((local / 'test-result.json').read_text())
    assert result['total'] == 10 and result['failures'] == 0 and result['excluded'] == 8 and result['skipped'] == 0, 'corrected two-case acceptance'
    receipt['complete'] = True
except BaseException as exc:
    receipt['failure'] = type(exc).__name__ + ': ' + str(exc)
finally:
    if active is not None:
        receipt['complete'] = False
        try:
            stop_owned(active, 0.5 if interrupted else 2)
        except subprocess.TimeoutExpired:
            receipt['cleanup_hold'] = 'active owned group requires reconciliation'
    try:
        post = bindings()
        (out / 'inputs-POST.json').write_text(json.dumps(post, sort_keys=True, indent=2))
        receipt['inputs_equal'] = pre == post
    except BaseException as exc:
        receipt['complete'] = False
        receipt['inputs_equal'] = False
        receipt['binding_failure'] = type(exc).__name__
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2))
print(json.dumps(receipt))
sys.exit(0 if receipt['complete'] else 1)
