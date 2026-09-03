import logging
import logging.handlers
from flask import Flask
from werkzeug.middleware.proxy_fix import ProxyFix
from .config import config_path, load_config, DEFAULT_SESSION_TIMEOUT_MINUTES
from .models import init_db

# gunicorn binds 127.0.0.1:5001 and nginx is the only thing that talks to it,
# so request.remote_addr is 127.0.0.1 for EVERY request. Nothing read nginx's
# X-Real-IP / X-Forwarded-For, so every session row and every login line in the
# log recorded the loopback address — an audit trail that cannot say who did
# anything, which is the one thing it exists to say.
#
# EXACTLY ONE HOP. nginx sets X-Forwarded-For with $proxy_add_x_forwarded_for,
# which APPENDS the real peer to whatever the client sent; ProxyFix with
# x_for=1 takes the last entry, i.e. the one nginx itself added. A larger
# number would start trusting values the client chose. x_host is 1 for the same
# reason and only because the nginx site sets X-Forwarded-Host itself — a
# trusted hop that does not set a header is a header the client controls.
_TRUSTED_PROXY_HOPS = 1


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
    # CSRF tokens are intentionally omitted: this is a pure JSON REST API
    # (no HTML form submissions). State-mutation routes enforce Content-Type:
    # application/json (force=True is not used) and cross-site fetches are
    # blocked via Sec-Fetch-Site checking in require_auth. SameSite=Lax is
    # an additional transport-level guard.
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

    from .routes import bp
    app.register_blueprint(bp)

    return app


def _setup_logging(cfg, app):
    log_cfg   = cfg.get('logging', {})
    level     = getattr(logging, log_cfg.get('log_level', 'INFO').upper(), logging.INFO)
    app.logger.setLevel(level)
    logging.getLogger('tm').setLevel(level)

    if log_cfg.get('syslog_enabled', False):
        # Log via local Unix socket (/dev/log) so rsyslog picks it up and
        # forwards to Graylog via the existing 60-graylog.conf rule (daemon.*).
        try:
            handler = logging.handlers.SysLogHandler(
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
