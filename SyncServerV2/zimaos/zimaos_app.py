#!/usr/bin/env python3
"""Loopback-only ZimaOS API client. Never print response bodies or credentials."""
import argparse
import contextlib
import fcntl
import getpass
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_TOKEN = '/DATA/AppData/fuminiwa-sync-v2-role-split/ops/zimaos-token.json'
LOGIN_HINT = 'zimaos_app.py login を実行してください'


class AppError(Exception):
    """Only fixed, credential-free messages may enter this exception."""


class APIError(AppError):
    def __init__(self, status, payload=None):
        # Even message can echo passwords, YAML or a newly rotated token.
        # Display only known credential-free messages; never arbitrary API text.
        message = payload.get('message') if isinstance(payload, dict) else None
        allowed = {'Unauthorized', 'invalid or expired jwt', 'Not Found',
                   'Bad Request', 'Forbidden', 'Conflict', 'Internal Server Error'}
        safe = message if isinstance(message, str) and message in allowed else 'API request failed (message withheld)'
        self.status = status
        super().__init__(f'HTTP {status}: {safe}')


def unwrap(value):
    while isinstance(value, dict) and 'data' in value:
        value = value['data']
    return value


def token_record(value, username):
    value = unwrap(value)
    if isinstance(value, dict) and isinstance(value.get('token'), dict):
        value = value['token']
    if not isinstance(value, dict):
        raise AppError('トークン応答の形式を確認できません')
    access, refresh, expires = (value.get(k) for k in ('access_token', 'refresh_token', 'expires_at'))
    if (not isinstance(access, str) or not access or not isinstance(refresh, str) or not refresh
            or any(c in access + refresh for c in '\r\n')
            or type(expires) not in (int, float) or not 0 < expires < 10**12):
        raise AppError('トークン応答の必須値が不足しています')
    return {'access_token': access, 'refresh_token': refresh, 'expires_at': expires,
            'saved_at': int(time.time()), 'username': username}


class TokenStore:
    def __init__(self, path=DEFAULT_TOKEN):
        self.path = Path(path)

    @contextlib.contextmanager
    def locked(self):
        # Shared by login, refresh and migration; rotation cannot race another CLI.
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        parent = self.path.parent.stat()
        if parent.st_uid != os.getuid() or parent.st_mode & 0o022:
            raise AppError('トークン保存先は本人所有・他者書込不可にしてください')
        fd = os.open(str(self.path) + '.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.getuid():
                raise AppError('トークンlockは本人所有の0600ファイルにしてください')
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            os.close(fd)

    def read(self):
        try:
            fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, 'r', encoding='utf-8') as source:
                info = os.fstat(source.fileno())
                if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.getuid():
                    raise AppError('トークンファイルは本人所有の0600にしてください')
                value = json.load(source)
            if not isinstance(value, dict) or not isinstance(value.get('username'), str):
                raise ValueError
            record = token_record(value, value['username'])
            record['saved_at'] = value.get('saved_at', 0)
            return record
        except AppError:
            raise
        except (OSError, ValueError, TypeError):
            raise AppError('トークンファイルを読み込めません。' + LOGIN_HINT) from None

    def save(self, value):
        # Existing unsafe files are not silently repaired/overwritten by login.
        if os.path.lexists(self.path):
            self.read()
        temporary = None
        try:
            fd, temporary = tempfile.mkstemp(prefix='.zimaos-token-', dir=self.path.parent)
            with os.fdopen(fd, 'w', encoding='utf-8') as destination:
                os.fchmod(destination.fileno(), 0o600)
                json.dump(value, destination, ensure_ascii=False)
                destination.write('\n')
                destination.flush()
                os.fsync(destination.fileno())
            os.replace(temporary, self.path)
            directory = os.open(self.path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        except OSError:
            raise AppError('トークン保存に失敗しました。' + LOGIN_HINT) from None
        finally:
            if temporary and os.path.exists(temporary):
                os.unlink(temporary)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, store=None, base='http://127.0.0.1', transport=None, clock=time.time):
        try:
            parsed = urllib.parse.urlsplit(base)
        except ValueError:
            raise AppError('API接続先が不正です') from None
        if (parsed.scheme != 'http' or parsed.hostname != '127.0.0.1' or parsed.username
                or parsed.password or parsed.path not in ('', '/') or parsed.query or parsed.fragment):
            raise AppError('API接続先は http://127.0.0.1 のみ許可します')
        # Validate port without exposing a malformed URL in an exception.
        try:
            parsed.port
        except ValueError:
            raise AppError('API接続先のportが不正です') from None
        self.base = base.rstrip('/')
        self.store = store or TokenStore()
        self.clock = clock
        self.prefix = ''
        self.redactions = set()
        self.transport = transport or self.http

    @staticmethod
    def http(request):
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        try:
            with opener.open(request, timeout=60) as response:
                return response.status, response.read(8 * 1024 * 1024)
        except urllib.error.HTTPError as error:
            return error.code, error.read(8 * 1024 * 1024)
        except (OSError, urllib.error.URLError, ValueError):
            raise AppError('APIに接続できません（詳細は非表示）') from None

    def request(self, method, path, body=None, token=None, yaml=False):
        if not path.startswith('/v') or path.startswith('//') or '\r' in path or '\n' in path:
            raise AppError('API pathが不正です')
        data = body if yaml else (json.dumps(body).encode() if body is not None else None)
        for attempt in range(2):
            headers = {'Content-Type': 'application/yaml' if yaml else 'application/json'}
            if token:
                headers['Authorization'] = self.prefix + token
            request = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
            try:
                status, contents = self.transport(request)
                try:
                    value = json.loads(contents) if contents else {}
                except (ValueError, TypeError):
                    value = {}
            except AppError:
                raise
            except Exception:
                raise AppError('API通信に失敗しました（詳細は非表示）') from None
            if status == 401 and token and not self.prefix and attempt == 0:
                self.prefix = 'Bearer '
                continue
            if not 200 <= status < 300:
                raise APIError(status, value)
            return value
        raise APIError(401)

    def access(self):
        with self.store.locked():
            record = self.store.read()
            self.redactions.update((record['access_token'], record['refresh_token']))
            if record['expires_at'] > self.clock() + 300:
                return record['access_token']
            try:
                response = self.request('POST', '/v1/users/refresh', {'refresh_token': record['refresh_token']})
                replacement = token_record(response, record['username'])
                if replacement['expires_at'] <= self.clock() + 300:
                    raise AppError('期限不足')
                self.redactions.update((replacement['access_token'], replacement['refresh_token']))
                self.store.save(replacement)
                return replacement['access_token']
            except AppError:
                raise AppError('トークンを更新できません。' + LOGIN_HINT) from None

    def login(self, username, password):
        with self.store.locked():
            response = self.request('POST', '/v1/users/login', {'username': username, 'password': password})
            self.store.save(token_record(response, username))

    def call(self, method, path, body=None, yaml=False):
        return self.request(method, path, body, self.access(), yaml)

    def apps(self):
        value = unwrap(self.call('GET', '/v2/app_management/compose'))
        if isinstance(value, dict):
            if not all(isinstance(item, dict) for item in value.values()):
                raise AppError('アプリ一覧の形式を確認できません')
            return [(str(key), item) for key, item in value.items()]
        if isinstance(value, list) and all(isinstance(item, dict) and (item.get('id') or item.get('app_id')) for item in value):
            return [(str(item.get('id') or item['app_id']), item) for item in value]
        raise AppError('アプリ一覧の形式を確認できません')

    def find(self, container):
        matches = []
        for app_id, item in self.apps():
            if contains_container(item, container):
                matches.append(app_id)
                continue
            detail = self.call('GET', app_path(app_id) + '/containers')
            if contains_container(detail, container):
                matches.append(app_id)
        if len(matches) > 1:
            raise AppError('同じコンテナを持つアプリが複数あります')
        return matches[0] if matches else None

    def install(self, compose, dry_run=False):
        body = Path(compose).read_bytes()
        query = '?dry_run=true&check_port_conflict=true'
        self.call('POST', '/v2/app_management/compose' + query, body, yaml=True)
        if dry_run:
            return None
        return self.call('POST', '/v2/app_management/compose?dry_run=false&check_port_conflict=true', body, yaml=True)

    def apply(self, app_id, compose):
        return self.call('PUT', app_path(app_id), Path(compose).read_bytes(), yaml=True)

    def uninstall(self, app_id):
        return self.call('DELETE', app_path(app_id) + '?delete_config_folder=false')

    def status(self, app_id):
        # Return only a safe summary, never a raw compose/inspect/API response.
        item = unwrap(self.call('GET', app_path(app_id)))
        containers = unwrap(self.call('GET', app_path(app_id) + '/containers'))
        health = unwrap(self.call('GET', app_path(app_id) + '/healthcheck'))
        return {'id': app_id, 'title': title(item), 'state': state(item),
                'containers': container_summary(containers), 'health': state(health)}


def app_path(app_id):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', app_id) or app_id in ('.', '..'):
        raise AppError('アプリidが不正です')
    return '/v2/app_management/compose/' + app_id


def contains_container(value, name):
    if isinstance(value, dict):
        return any(contains_container(child, name) for child in value.values())
    if isinstance(value, list):
        return any(contains_container(child, name) for child in value)
    if isinstance(value, str):
        if value.lstrip().startswith(('{', '[')):
            try:
                return contains_container(json.loads(value), name)
            except ValueError:
                pass
        return value in (name, '/' + name) or bool(re.search(
            r'(?m)^\s*[\"\']?container_name[\"\']?\s*:\s*[\"\']?' + re.escape(name) + r'[\"\']?\s*$', value))
    return False


def title(item):
    if not isinstance(item, dict):
        return '-'
    value = item.get('title') or item.get('name')
    if not value:
        value = item.get('x-casaos', {}).get('title', '-') if isinstance(item.get('x-casaos'), dict) else '-'
    if isinstance(value, dict):
        value = value.get('ja_JP') or value.get('en_US') or '-'
    return value if isinstance(value, str) else '-'


def state(item):
    if isinstance(item, dict):
        item = item.get('state') or item.get('status') or item.get('State') or item.get('Status')
        if isinstance(item, dict):
            item = item.get('Status') or item.get('status')
    # Unknown API text is not safe diagnostic output.
    return item if item in ('running', 'stopped', 'healthy', 'unhealthy', 'starting', 'exited', 'created', 'restarting') else 'unknown'


def container_summary(value):
    if isinstance(value, dict):
        value = list(value.values())
    if not isinstance(value, list):
        return []
    return [{'name': item.get('Name', item.get('name', '-')), 'state': state(item)}
            for item in value if isinstance(item, dict)]


def safe_display(value, tokens):
    text = json.dumps(value, ensure_ascii=False) if not isinstance(value, str) else value
    for token in tokens:
        text = text.replace(token, '[redacted]')
    text = re.sub(r'[A-Za-z0-9_+/=-]{32,}', '[redacted]', text)
    return ''.join(char for char in text if ord(char) >= 32 or char == '\t')[:4096]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--token-file', default=DEFAULT_TOKEN)
    parser.add_argument('--base-url', default='http://127.0.0.1')
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('login')
    commands.add_parser('list')
    find = commands.add_parser('find')
    find.add_argument('--container', required=True)
    install = commands.add_parser('install')
    install.add_argument('compose')
    install.add_argument('--dry-run', action='store_true')
    apply = commands.add_parser('apply')
    apply.add_argument('id')
    apply.add_argument('compose')
    remove = commands.add_parser('uninstall')
    remove.add_argument('id')
    status = commands.add_parser('status')
    status.add_argument('id')
    args = parser.parse_args(argv)
    try:
        client = Client(TokenStore(args.token_file), args.base_url)
        if args.command == 'login':
            username = input('ユーザー名: ')
            password = getpass.getpass('パスワード: ')
            client.login(username, password)
            print('保存しました')
            return 0
        # Used only to redact structured metadata; no credentials are printed.
        client.access()
        tokens = client.redactions
        if args.command == 'list':
            for app_id, item in client.apps():
                print(safe_display(f'{app_id}\t{title(item)}\t{state(item)}', tokens))
        elif args.command == 'find':
            app_id = client.find(args.container)
            if app_id is None:
                return 3
            app_path(app_id)
            if any(secret in app_id for secret in tokens):
                raise AppError('アプリidを安全に表示できません')
            print(app_id)
        elif args.command == 'install':
            client.install(args.compose, args.dry_run)
            print('dry-run成功' if args.dry_run else 'インストール要求を送信しました')
        elif args.command == 'apply':
            client.apply(args.id, args.compose)
            print('設定適用を要求しました')
        elif args.command == 'uninstall':
            client.uninstall(args.id)
            print('削除を要求しました（設定フォルダは保持）')
        elif args.command == 'status':
            print(safe_display(client.status(args.id), tokens))
        return 0
    except AppError as error:
        print(str(error))
    except (Exception, KeyboardInterrupt):
        print('処理に失敗しました（詳細は非表示）')
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
