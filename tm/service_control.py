"""
Service restart control.

MECHANISM — polkit, not sudo. Measured on prod 2026-08-30/09-01:

  * The unit sets NoNewPrivileges=true, and sudo refuses outright under it
    ("the 'no new privileges' flag is set"). sudoers is dead as the unit
    stands, and the hardening is not being removed to revive it.
  * `systemctl` over D-Bus survives NoNewPrivileges, because the caller never
    escalates — it asks PID 1 to act. The denial seen without a rule is
    "Interactive authentication required", i.e. polkit, not the sandbox.

So install/polkit/50-topic-manager.rules authorises the `topic-manager` user
for org.freedesktop.systemd1.manage-units on an explicit unit + verb
allowlist, and polkitd journals every authorisation.

nginx: RELOAD by default, hard restart only when the operator ticks the box.
Nothing in this release changes nginx's configuration, so a restart buys
nothing a reload does not, and it drops every other user's in-flight request.

`nginx -t` runs BEFORE any nginx action and its failure refuses the action.
It cannot be run by this process directly: measured on prod, `nginx -t` as
the topic-manager user dies with
    [emerg] open() "/run/nginx.pid" failed (13: Permission denied)
and `-g 'pid ...;'` collides with the pid directive nginx.conf already sets.
It therefore runs as root through topic-manager-nginx-test.service, a
Type=oneshot unit whose ExecStart is a fixed absolute path in a root-owned
unit file. `systemctl start` on a oneshot unit blocks until it finishes and
exits non-zero when it fails, so the verdict is conclusive.

SEQUENCING — the 202 is flushed first, then nginx, then topic-manager LAST,
because restarting topic-manager kills the worker running the handler.

RATE — `restart` is a PERSISTENT STOP primitive, which is why claim_restart_slot
exists. Both units carry systemd's defaults, MEASURED on prod 2026-09-01:
StartLimitIntervalUSec=10s and StartLimitBurst=5. Five starts inside ten seconds
trips the limiter and systemd then REFUSES to start the unit at all until a
`systemctl reset-failed`. Any authenticated user can reach POST
/api/service/restart, so five clicks — or five requests — wedge the application
AND, with the hard-nginx box ticked, the web server that serves the control used
to fix it. No code execution is needed for that.

Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
"""
import logging
import shutil
import signal
import subprocess
import threading
import time

from .models import get_db

log = logging.getLogger(__name__)

SERVICE_UNIT = 'topic-manager.service'
NGINX_UNIT = 'nginx.service'
NGINX_TEST_UNIT = 'topic-manager-nginx-test.service'

# Exactly the units the polkit rule authorises. Kept here as well so a route
# cannot ask for a unit the rule would refuse and get an opaque polkit error.
ALLOWED_UNITS = (SERVICE_UNIT, NGINX_UNIT, NGINX_TEST_UNIT)

_TIMEOUT = 30           # seconds, per systemctl invocation
_FLUSH_DELAY = 0.75     # seconds; let gunicorn finish writing the 202

# THE DECISION, not a guess. The limiter that must never be tripped is
# 5 starts / 10s (systemd's DefaultStartLimitBurst / DefaultStartLimitInterval,
# measured on both units). One start per 30s is a single start inside any 10s
# window, which is 1 of the 5 allowed, and it leaves an operator who genuinely
# needs a second restart waiting well under a minute. Move this number and you
# are moving how close the product runs to a self-inflicted outage, so it is a
# named constant and the tests assert against IT, not against a literal.
RESTART_MIN_INTERVAL_S = 30

# Where the interval is remembered. NOT a module global: gunicorn runs FOUR
# workers, each a separate process with its own memory, so an in-process cache
# throttles one worker in four and the other three restart on demand. The
# audit database is the only thing all four already share, and SQLite gives the
# claim below its atomicity for free.
_RESTART_KEY = 'service_restart_last_epoch'


def claim_restart_slot(cfg, now=None):
    """
    Claim the right to restart, for every worker at once.

    Returns (True, 0.0) when this caller may proceed, or (False, seconds) with
    the time still to wait. The claim is a single UPSERT whose WHERE clause is
    the cooldown itself, so the read and the write cannot be separated by
    another worker: SQLite serialises the statement, exactly one caller sees
    rowcount 1, and everyone else is refused. That is the single-flight half —
    two simultaneous requests cannot both be accepted — and the cooldown half
    at the same time.
    """
    now = time.time() if now is None else now
    db = get_db(cfg)
    try:
        cur = db.execute(
            'INSERT INTO app_settings (key, value) VALUES (?, ?) '
            'ON CONFLICT(key) DO UPDATE SET value = excluded.value '
            '  WHERE CAST(excluded.value AS REAL) - CAST(app_settings.value AS REAL) >= ?',
            (_RESTART_KEY, '%.6f' % now, RESTART_MIN_INTERVAL_S),
        )
        claimed = cur.rowcount == 1
        db.commit()
        if claimed:
            return True, 0.0
        row = db.execute(
            'SELECT value FROM app_settings WHERE key = ?', (_RESTART_KEY,)
        ).fetchone()
    finally:
        db.close()
    try:
        last = float(row[0]) if row and row[0] is not None else now
    except ValueError:
        # Something other than this function wrote the key. Refusing on an
        # unreadable claim is the safe direction: the alternative is treating a
        # value we cannot parse as "no restart has happened".
        last = now
    remaining = RESTART_MIN_INTERVAL_S - (now - last)
    return False, remaining if remaining > 0 else float(RESTART_MIN_INTERVAL_S)


def _systemctl():
    return shutil.which('systemctl') or '/usr/bin/systemctl'


def _run(args):
    """Run one systemctl invocation. Returns (returncode, combined output)."""
    try:
        proc = subprocess.run(
            args,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=_TIMEOUT, check=False,
        )
    except subprocess.TimeoutExpired:
        return 124, '%s timed out after %ds' % (' '.join(args), _TIMEOUT)
    except OSError as exc:
        return 127, '%s could not be executed: %s' % (args[0], exc)
    return proc.returncode, proc.stdout.decode('utf-8', 'replace').strip()


def _unit_action(verb, unit, extra=()):
    if unit not in ALLOWED_UNITS:
        raise ValueError('%s is not an allowed unit' % unit)
    return _run([_systemctl(), verb, *extra, unit])


def nginx_config_test():
    """
    Run `nginx -t` as root via the oneshot test unit.

    Returns (ok, detail). A failure to RUN the test is a failure, never a pass:
    an nginx action must not proceed on an untested configuration.
    """
    rc, out = _unit_action('start', NGINX_TEST_UNIT)
    if rc == 0:
        return True, 'nginx -t passed'
    detail = out or 'no output'
    return False, ('nginx -t did not pass (systemctl exit %d): %s. '
                   'Run `sudo nginx -t` on the host for the full diagnostic.'
                   % (rc, detail))


def _restart_sequence(hard_nginx, on_result):
    """
    The detached half. Runs after the 202 has been flushed.

    nginx first and topic-manager last: restarting topic-manager kills the
    worker this thread lives in, so anything after it would not run.
    """
    time.sleep(_FLUSH_DELAY)

    verb = 'restart' if hard_nginx else 'reload'
    rc, out = _unit_action(verb, NGINX_UNIT)
    if rc == 0:
        on_result('nginx %sed' % verb)
    else:
        # Report it and carry on: the topic-manager restart is independent of
        # nginx, and stopping here would leave the operator with neither.
        on_result('nginx %s FAILED (exit %d): %s' % (verb, rc, out or 'no output'))

    # --no-block: systemd queues the job and systemctl returns immediately.
    # Waiting would mean waiting for the process this thread runs in to be
    # killed, and the client would be reaped with the cgroup either way.
    rc, out = _unit_action('restart', SERVICE_UNIT, extra=('--no-block',))

    # Being SIGTERMed here is SUCCESS, not failure. systemd stops the whole
    # cgroup, and this systemctl client is inside the very unit it just asked
    # to restart — so it is killed before it can report, and returncode comes
    # back as -SIGTERM (and occasionally -SIGKILL, after TimeoutStopSec).
    #
    # Measured on prod 2026-09-02: the unit restarted cleanly
    # (Result=success, NRestarts=0, a clean Stopped -> Started pair) while this
    # branch wrote "topic-manager restart FAILED (exit -15)" into the audit log.
    # An operator reading that would conclude restarts are broken when they
    # work. That is hazards[misleading-failure-message] — the same defect this
    # project has already removed from die() and from the upgrade summary, so
    # do not reintroduce it by treating a signal as an exit status.
    _EXPECTED_SELF_KILL = (-signal.SIGTERM, -signal.SIGKILL)
    if rc == 0:
        on_result('topic-manager restart queued')
    elif rc in _EXPECTED_SELF_KILL:
        on_result('topic-manager restart queued; this worker was replaced '
                  'mid-call (signal %d), which is the expected outcome' % -rc)
    else:
        on_result('topic-manager restart FAILED (exit %d): %s'
                  % (rc, out or 'no output'))


def restart_detached(hard_nginx, on_result):
    """
    Start the restart sequence on a daemon thread and return immediately, so
    the caller can flush its 202 before anything is touched.

    `on_result` is called with a one-line outcome for each step; the route
    passes an audit-logging callback, because the worker is about to die and
    the UI cannot be told directly.
    """
    thread = threading.Thread(
        target=_restart_sequence,
        args=(hard_nginx, on_result),
        name='tm-service-restart',
        daemon=True,
    )
    thread.start()
    return thread
