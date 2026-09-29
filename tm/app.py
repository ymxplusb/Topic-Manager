import hashlib
import logging
import logging.handlers
from flask import Flask
from flask.sessions import SecureCookieSessionInterface
from werkzeug.middleware.proxy_fix import ProxyFix
from .config import config_path, load_config, DEFAULT_SESSION_TIMEOUT_MINUTES
from .models import init_db, get_db
from . import audit, settings_schema
from . import apply as apply_mod

# nginx is the only thing that talks to gunicorn — since v1.2.0 over a Unix
# socket only it and the service account can open (systemd/topic-manager.socket),
# before that over 127.0.0.1:5001 — so the peer address is never the client's.
# Nothing read nginx's X-Real-IP / X-Forwarded-For, so every session row and
# every login line recorded the loopback address — an audit trail that cannot
# say who did anything, which is the one thing it exists to say.
#
# THE SOCKET IS WHAT MAKES x_for=1 SAFE. On 127.0.0.1:5001 any local process
# could connect directly and send an X-Forwarded-For of its choosing, which
# this would have believed (adversary F-05). Only nginx can send one now.
#
# EXACTLY ONE HOP. nginx sets X-Forwarded-For with $proxy_add_x_forwarded_for,
# which APPENDS the real peer to whatever the client sent; ProxyFix with
# x_for=1 takes the last entry, i.e. the one nginx itself added. A larger
# number would start trusting values the client chose. x_host is 1 for the same
# reason and only because the nginx site sets X-Forwarded-Host itself — a
# trusted hop that does not set a header is a header the client controls.
_TRUSTED_PROXY_HOPS = 1


class Sha256SessionInterface(SecureCookieSessionInterface):
    """Flask's signed session cookie, signed with HMAC-SHA-256.

    Flask's default digest is SHA-1 (flask.sessions._lazy_sha1). The cookie
    carries only the server-side session id, but it IS signed, and on a FIPS
    host the rule is simple: no SHA-1 for a security purpose. The key
    derivation (key_derivation='hmac') uses the same digest. Changing it
    invalidates every cookie signed under SHA-1, so an upgrade signs everyone
    out once — expected, and harmless.
    """
    digest_method = staticmethod(hashlib.sha256)


def create_app(config_path_arg=None):
    app = Flask(__name__, static_folder=None)
    app.wsgi_app = ProxyFix(
        app.wsgi_app,
        x_for=_TRUSTED_PROXY_HOPS,
        x_proto=_TRUSTED_PROXY_HOPS,
        x_host=_TRUSTED_PROXY_HOPS,
    )

    resolved_path = config_path(config_path_arg)
    cfg = load_config(resolved_path)

    _secret = cfg.get('server', {}).get('secret_key', '')
    if not _secret or 'CHANGE_ME' in _secret:
        raise RuntimeError(
            'server.secret_key is not set or still contains the placeholder. '
            'Generate one with: python3 -c "import secrets; print(secrets.token_hex(32))"'
        )
    app.secret_key = _secret
    app.session_interface = Sha256SessionInterface()
    # CSRF: no token. Every state-changing /api/ request must be marked as
    # this origin's own - Sec-Fetch-Site: same-origin, or the X-TM-Request: 1
    # header the SPA adds (tm/routes.py _refuse_cross_site, a before_request
    # on every route). JSON Content-Type alone was not enough: the TLS
    # certificate upload is multipart/form-data, which a plain HTML form on
    # another site can send. SameSite=Lax is an additional transport guard.
    app.config['SESSION_COOKIE_HTTPONLY'] = True
    app.config['SESSION_COOKIE_SAMESITE'] = 'Lax'
    app.config['SESSION_COOKIE_SECURE']   = True
    app.config['PERMANENT_SESSION_LIFETIME'] = (
        cfg.get('session', {}).get('timeout_minutes',
                                   DEFAULT_SESSION_TIMEOUT_MINUTES) * 60
    )
    # The PATH, not the parsed dict. app.config['TM_CONFIG'] used to hold a
    # config frozen at create_app; routes read it on every request, so a
    # cluster written by one of the four gunicorn workers stayed invisible to
    # all of them until a restart. tm/routes._cfg() now calls load_config(),
    # which re-reads only when the file's (inode, size, mtime) has moved.
    app.config['TM_CONFIG_PATH'] = resolved_path

    _setup_logging(cfg, app)
    init_db(cfg)
    # v1.2.0: the concurrent-session limit lives in Settings. config.yaml's
    # session.max_concurrent seeds it once, on the first start against a
    # database that has no value, and a later disagreement is logged here at
    # every start (owner ruling: Settings wins).
    db = get_db(cfg)
    try:
        settings_schema.seed_session_limit(cfg, db)
    finally:
        db.close()
    # Any "Apply to host" that finished while nothing was polling (the browser
    # closed, the service restarting) is recorded now. Safe from all four
    # workers at once: each job is claimed by one conditional UPSERT.
    apply_mod.audit_all_results(cfg)

    from .routes import bp
    app.register_blueprint(bp)

    return app


class _BoundedSysLogHandler(logging.handlers.SysLogHandler):
    """SysLogHandler whose Unix socket never blocks for longer than
    audit.SYSLOG_SEND_TIMEOUT. The stock handler's datagram send blocks while
    the syslog daemon's receive queue is full, so a stalled journald/rsyslog
    hung every worker at its next log line, and the CRITICAL that reports a
    failed audit send would have hung the worker the audit fix just freed. A
    send past the bound raises inside the handler, which logging reports on
    stderr (handleError) and carries on."""

    def _connect_unixsocket(self, address):
        super()._connect_unixsocket(address)
        self.socket.settimeout(audit.SYSLOG_SEND_TIMEOUT)


def _setup_logging(cfg, app):
    log_cfg   = cfg.get('logging', {})
    level     = getattr(logging, log_cfg.get('log_level', 'INFO').upper(), logging.INFO)
    app.logger.setLevel(level)
    logging.getLogger('tm').setLevel(level)

    if log_cfg.get('syslog_enabled', False):
        # Log via the local Unix socket (/dev/log) to the host's syslog
        # daemon, facility daemon. Forwarding it off the host is the host's
        # rsyslog configuration, not this application's.
        try:
            handler = _BoundedSysLogHandler(
                address='/dev/log',
                facility=logging.handlers.SysLogHandler.LOG_DAEMON,
            )
            handler.setFormatter(
                logging.Formatter('topic-manager[%(process)d]: %(levelname)s %(message)s')
            )
            handler.setLevel(level)
            app.logger.addHandler(handler)
            logging.getLogger('tm').addHandler(handler)
        except Exception as exc:
            app.logger.warning('Could not attach syslog handler: %s', exc)
