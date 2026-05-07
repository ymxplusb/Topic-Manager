import os
import secrets
import logging
import logging.handlers
from flask import Flask
from .config import load_config
from .models import init_db


def create_app(config_path=None):
    app = Flask(__name__, static_folder=None)

    cfg = load_config(config_path)

    app.secret_key = cfg.get('server', {}).get('secret_key') or secrets.token_hex(32)
    # CSRF tokens are intentionally omitted: this is a pure JSON REST API
    # (no HTML form submissions). State-mutation routes require Content-Type:
    # application/json, and the SameSite=Lax cookie policy prevents cross-site
    # request forgery from third-party origins.
    app.config['SESSION_COOKIE_HTTPONLY'] = True
    app.config['SESSION_COOKIE_SAMESITE'] = 'Lax'
    app.config['SESSION_COOKIE_SECURE']   = True
    app.config['PERMANENT_SESSION_LIFETIME'] = (
        cfg.get('session', {}).get('timeout_minutes', 30) * 60
    )
    app.config['TM_CONFIG'] = cfg

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
