import os
import secrets
from flask import Flask
from .config import load_config
from .models import init_db


def create_app(config_path=None):
    app = Flask(__name__, static_folder=None)

    cfg = load_config(config_path)

    app.secret_key = cfg.get('server', {}).get('secret_key') or secrets.token_hex(32)
    app.config['SESSION_COOKIE_HTTPONLY'] = True
    app.config['SESSION_COOKIE_SAMESITE'] = 'Lax'
    app.config['SESSION_COOKIE_SECURE'] = True
    app.config['PERMANENT_SESSION_LIFETIME'] = (
        cfg.get('session', {}).get('timeout_minutes', 30) * 60
    )
    app.config['TM_CONFIG'] = cfg

    init_db(cfg)

    from .routes import bp
    app.register_blueprint(bp)

    return app
