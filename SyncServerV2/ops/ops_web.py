#!/usr/bin/env python3
"""Local operator UI: fixed Docker reads and one backup action, stdlib only."""
import argparse
import base64
import datetime as dt
import fcntl
import hashlib
import hmac
import html
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import select
import stat
import subprocess
import sys
import threading
from urllib.parse import parse_qs, urlsplit

import ops

PASSWORD_FILE = Path('/run/secrets/ops-ui-password')
CONTAINERS = ('fuminiwa-sync-v2-role-split-postgres',
              'fuminiwa-sync-v2-role-split-server',
              'fuminiwa-sync-v2-role-split-edge', 'fuminiwa-sync-v2-ops',
              'fuminiwa-registry')
BACKUP_NAME = re.compile(r'[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}')
ANSI = re.compile(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))')
SENSITIVE = re.compile(r'(?i)(password|secret|private.?key|vault.?key|hmac.?key|'
                       r'authorization|bearer|access.?token|refresh.?token|'
                       r'client.?secret|-----BEGIN|-----END|FUMINIWA_[A-Z_]+=)')
ICON = b'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96"><rect width="96" height="96" rx="22" fill="#336c59"/><path d="M24 25h20q8 0 8 8v39q-8-8-28-8zm48 0H56v39q8-5 16-5z" fill="#fff"/></svg>'''


def load_password(path=PASSWORD_FILE):
    try:
        metadata = path.stat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077:
            raise ValueError('password file must be private')
        raw = path.read_bytes()
        password = raw.rstrip(b'\r\n')
        if not 16 <= len(password) <= 1024 or b'\n' in password or b'\r' in password:
            raise ValueError('invalid password file')
        return password
    except FileNotFoundError:
        return None


def docker(*arguments):
    # Callers below are fixed; HTTP input never reaches a command or a name.
    result = subprocess.run(['docker', *arguments], capture_output=True,
                            timeout=10, check=False)
    if result.returncode:
        raise ValueError('Docker read failed')
    return result.stdout + (result.stderr if arguments[0] == 'logs' else b'')


class Dashboard:
    def __init__(self, password, root=ops.BACKUP_DIRECTORY, reader=docker, runner=None):
        self.password = hashlib.sha256(password).digest()
        self.redactions = {password.decode('utf-8', errors='replace')}
        self.token = secrets.token_urlsafe(32)
        self.root, self.reader = root, reader
        self.runner = runner or (lambda lock: ops.run_backup(ops.load_config(), backup_lock=lock))
        self.guard = threading.Lock()
        self.render_guard = threading.Lock()
        self.running = False
        self.result = None

    def authenticated(self, header):
        try:
            scheme, encoded = header.split(' ', 1)
            if scheme.lower() != 'basic':
                return False
            username, password = base64.b64decode(encoded, validate=True).split(b':', 1)
            user_ok = hmac.compare_digest(hashlib.sha256(username).digest(), hashlib.sha256(b'admin').digest())
            pass_ok = hmac.compare_digest(hashlib.sha256(password).digest(), self.password)
            return user_ok & pass_ok
        except (ValueError, TypeError):
            return False

    def begin_backup(self):
        with self.guard:
            if self.running:
                return False
            lock = (self.root / '.lock').open('a')
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                lock.close()
                return False
            self.running = True
            self.result = None
            def work():
                result = '失敗（opsログを確認してください）'
                try:
                    if self.runner(lock) == 0:
                        result = '成功'
                except Exception:
                    print('ops-ui: backup failed', flush=True)
                finally:
                    lock.close()
                    with self.guard:
                        self.running, self.result = False, result
            try:
                threading.Thread(target=work, daemon=True).start()
            except Exception:
                self.running = False
                lock.close()
                raise
            return True

    def busy(self):
        with self.guard:
            if self.running:
                return True
        with (self.root / '.lock').open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return False
            except BlockingIOError:
                return True

    def sanitize(self, value):
        value = ANSI.sub('', value)
        value = ''.join(c for c in value if c in '\n\t' or ord(c) >= 32)
        for secret in sorted(self.redactions, key=len, reverse=True):
            if secret:
                value = value.replace(secret, '[非表示]')
        lines = []
        for line in value.splitlines()[-100:]:
            if SENSITIVE.search(line) or re.search(r'[A-Za-z0-9_+/=-]{32,}', line):
                line = '[機密情報を含む可能性がある行を非表示]'
            lines.append(line[:2000])
        return '\n'.join(lines)

    def render(self):
        e = lambda value: html.escape(str(value), quote=True)
        rows = []
        for name in CONTAINERS:
            try:
                item = json.loads(self.reader('inspect', name))[0]
                # Never render Config, Env, healthcheck output or inspect errors.
                for pair in item.get('Config', {}).get('Env', []):
                    value = pair.partition('=')[2]
                    if len(value) >= 4:
                        self.redactions.add(value)
                state = item['State']
                cells = [name, state['Status'], state.get('Health', {}).get('Status', '—'),
                         item['HostConfig']['RestartPolicy']['Name'], state['StartedAt']]
            except Exception:
                cells = [name, '取得できません', '—', '—', '—']
            rows.append('<tr>' + ''.join('<td>' + e(v) + '</td>' for v in cells) + '</tr>')
        try:
            status = json.loads((self.root / 'last-success.json').read_text())
            completed = dt.datetime.fromisoformat(status['completed_at'])
            if completed.tzinfo is None or not BACKUP_NAME.fullmatch(status['backup']):
                raise ValueError('invalid success')
            last = e(completed.isoformat()) + ' / ' + e(status['backup'])
        except Exception:
            last = '成功記録なし／読取不可'
        backups = []
        for folder in sorted(self.root.iterdir(), key=lambda p: p.name, reverse=True):
            if folder.is_symlink() or not BACKUP_NAME.fullmatch(folder.name) or not folder.is_dir():
                continue
            try:
                manifest = folder / 'manifest.json'
                if manifest.is_symlink():
                    continue
                record = json.loads(manifest.read_text())
                names = record['files']
                if record.get('version') != 1 or set(names) not in (
                        {'database.enc', 'secrets.enc'},
                        {'database.enc', 'secrets.enc', 'configuration.enc'}):
                    continue
                files = [manifest] + [folder / name for name in set(names)]
                if any(p.is_symlink() for p in files) or not all(p.is_file() for p in files):
                    continue
                size = sum(p.stat().st_size for p in files)
                backups.append('<li>' + e(folder.name) + ' — ' + e(f'{size:,}') + ' bytes</li>')
            except (OSError, ValueError, KeyError, TypeError):
                continue
            if len(backups) >= 20:
                break
        logs = []
        for name in (CONTAINERS[1], CONTAINERS[3]):
            try:
                value = self.reader('logs', '--tail', '100', name).decode('utf-8', errors='replace')
                value = self.sanitize(value)
            except Exception:
                value = 'ログを取得できません'
            logs.append('<h3>' + e(name) + '</h3><pre>' + e(value) + '</pre>')
        upcoming = ops.next_execution(os.environ, dt.datetime.now(ops.UTC)).isoformat()
        busy = self.busy()
        notice = 'バックアップ実行中' if busy else (self.result or '待機中')
        return f'''<!doctype html><html lang="ja"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>ふみにわ同期</title>
<style>:root{{color-scheme:light dark;font-family:system-ui,sans-serif}}body{{max-width:1100px;margin:auto;padding:20px;line-height:1.6}}h1{{font-size:1.6rem}}.scroll{{overflow:auto}}table{{border-collapse:collapse;width:100%}}td,th{{text-align:left;padding:8px;border-bottom:1px solid #8885}}td:first-child{{overflow-wrap:anywhere}}pre{{padding:12px;background:#8881;white-space:pre-wrap;overflow-wrap:anywhere;max-height:30em;overflow:auto}}button,a{{font:inherit}}button{{padding:10px 18px;cursor:pointer}}li{{overflow-wrap:anywhere}}</style>
<h1>ふみにわ同期</h1><p><a href="/">表示を更新</a>（自動更新なし）</p><h2>コンテナ</h2><div class="scroll"><table><tr><th>名前</th><th>状態</th><th>health</th><th>restart</th><th>起動時刻</th></tr>{''.join(rows)}</table></div>
<h2>バックアップ</h2><p>最後の成功: {last}<br>次回予定: {e(upcoming)}<br>{e(notice)}</p>
<form method="post" action="/backup"><input type="hidden" name="token" value="{self.token}"><button {'disabled' if busy else ''}>今すぐバックアップ</button></form>
<p>定期・CLI実行と同じロックで排他します。完了後に表示を更新してください。</p><h3>直近20件（完了ファイルのみ）</h3><ul>{''.join(backups) or '<li>なし</li>'}</ul><h2>直近ログ（最大100行）</h2>{''.join(logs)}</html>'''.encode()


class Handler(BaseHTTPRequestHandler):
    server_version = 'FuminiwaOps'
    sys_version = ''

    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def log_message(self, *args):
        pass  # URLs, credentials and request contents never enter logs.

    def reply(self, code, body=b'', content_type='text/plain; charset=utf-8', extra=()):
        self.send_response(code)
        for key, value in [('Content-Type', content_type), ('Content-Length', str(len(body))),
                           ('Cache-Control', 'no-store'), ('X-Content-Type-Options', 'nosniff'),
                           ('Referrer-Policy', 'no-referrer'),
                           ('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"), *extra]:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def authorize(self):
        if not self.server.dashboard.authenticated(self.headers.get('Authorization', '')):
            self.reply(401, b'Authentication required', extra=[('WWW-Authenticate', 'Basic realm="Fuminiwa Ops", charset="UTF-8"')])
            return False
        return True

    def do_GET(self):
        if self.path == '/icon.svg':
            self.reply(200, ICON, 'image/svg+xml')
            return
        if not self.authorize():
            return
        if self.path != '/':
            self.reply(404)
            return
        try:
            with self.server.dashboard.render_guard:
                body = self.server.dashboard.render()
            self.reply(200, body, 'text/html; charset=utf-8')
        except Exception:
            self.reply(503, '状態を取得できません'.encode())

    def do_POST(self):
        self.close_connection = True
        if not self.authorize():
            return
        if self.path != '/backup':
            self.reply(404)
            return
        try:
            origin = urlsplit(self.headers.get('Origin', ''))
            host = self.headers.get('Host', '')
            if (origin.scheme != 'http' or not host or origin.netloc.lower() != host.lower()
                    or origin.path or origin.query or origin.fragment or origin.username is not None):
                raise ValueError('origin mismatch')
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= 2048 or self.headers.get('Transfer-Encoding'):
                raise ValueError('invalid size')
            if self.headers.get('Content-Type', '').split(';')[0] != 'application/x-www-form-urlencoded':
                raise ValueError('invalid form')
            form = parse_qs(self.rfile.read(size).decode('ascii'), strict_parsing=True)
            if set(form) != {'token'} or len(form['token']) != 1 or not hmac.compare_digest(form['token'][0].encode(), self.server.dashboard.token.encode()):
                raise ValueError('invalid token')
        except (ValueError, UnicodeError):
            self.reply(403, b'CSRF rejected')
            return
        try:
            if not self.server.dashboard.begin_backup():
                self.reply(409, 'バックアップ実行中'.encode())
                return
            self.reply(303, extra=[('Location', '/')])
        except Exception:
            self.reply(503, 'バックアップを開始できません'.encode())


def make_server(address, dashboard):
    server = ThreadingHTTPServer(address, Handler)
    server.daemon_threads = True
    server.dashboard = dashboard
    return server


def start_background():
    """Start before exec of Supercronic; missing/invalid secret disables only UI."""
    try:
        password = load_password()
        if password is None:
            print('ops-ui: disabled (password not configured)', flush=True)
            return
        del password
        port = int(os.environ.get('OPS_UI_PORT', '8790'))
        if not 1024 <= port <= 65535:
            raise ValueError('invalid port')
        read_fd, write_fd = os.pipe()
        try:
            child = subprocess.Popen([sys.executable, str(Path(__file__)), '--ready-fd', str(write_fd)], pass_fds=(write_fd,))
            os.close(write_fd)
            write_fd = None
            if not select.select([read_fd], [], [], 10)[0] or os.read(read_fd, 1) != b'1':
                child.terminate()
                child.wait(timeout=5)
                raise ValueError('UI startup failed')
            (ops.STATE_DIRECTORY / 'ops-ui.pid').write_text(str(child.pid))
        finally:
            os.close(read_fd)
            if write_fd is not None:
                os.close(write_fd)
    except Exception:
        print('ops-ui: disabled (password/port/startup error)', flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ready-fd', type=int)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        ops.become_ops()
        password = load_password()
        if password is None:
            return 1
        server = make_server(('0.0.0.0', int(os.environ.get('OPS_UI_PORT', '8790'))), Dashboard(password))
        if args.ready_fd is not None:
            os.write(args.ready_fd, b'1')
            os.close(args.ready_fd)
        print('ops-ui: listening', flush=True)
        server.serve_forever(poll_interval=10)
    except Exception:
        print('ops-ui: stopped (configuration/runtime error)', flush=True)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
