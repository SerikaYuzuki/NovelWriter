#!/usr/bin/env python3
"""Testable, fail-closed migration engine; shell wrapper supplies Docker config."""
import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import tempfile
import time

from zimaos_app import AppError, Client, DEFAULT_TOKEN, TokenStore, app_path
from render_app_compose import NAMES, EXTERNAL_MOUNTS

DEFAULT_STATE = '/DATA/AppData/fuminiwa-sync-v2-role-split/ops/zimaos-migration.json'
PUBLIC_URL = 'https://sync.serika.work/v1/auth/capabilities'
LOCAL_URL = 'https://127.0.0.1:8443/v1/auth/capabilities'


class MigrationError(AppError):
    pass


def expected_mounts(document):
    """Normalize Compose's JSON (including secrets) into exact inspect contracts."""
    services = document.get('services', {})
    if set(services) != set(NAMES):
        raise MigrationError('composeは指定の4サービスだけにしてください')
    external = {name for value in EXTERNAL_MOUNTS.values() for name in value.values()}
    volumes = document.get('volumes', {})
    if set(volumes) != external or any(volumes[n].get('external') is not True or volumes[n].get('name') != n for n in external):
        raise MigrationError('external volume設定が一致しません')
    result = {}
    for role, service in services.items():
        if service.get('container_name') != NAMES[role] or service.get('restart') != 'unless-stopped':
            raise MigrationError('container_nameまたはrestart設定が一致しません')
        mounts = {}
        for entry in service.get('volumes', []):
            if not isinstance(entry, dict) or entry.get('type') not in ('bind', 'volume'):
                raise MigrationError('compose configのmount形式が不明です')
            target, source = entry.get('target'), entry.get('source')
            if not isinstance(target, str) or not isinstance(source, str) or target == '/config' or target in mounts:
                raise MigrationError('mountターゲットが不正です')
            kind = entry['type']
            if kind == 'volume':
                if EXTERNAL_MOUNTS.get(role, {}).get(target) != source:
                    raise MigrationError('named volume設定が一致しません')
                source = volumes[source]['name']
            elif not source.startswith('/'):
                raise MigrationError('bindは絶対パスが必要です')
            mounts[target] = {'type': kind, 'source': source, 'rw': not entry.get('read_only', False)}
        for entry in service.get('secrets', []):
            if not isinstance(entry, dict):
                raise MigrationError('compose configのsecret形式が不明です')
            name = entry.get('source')
            source = document.get('secrets', {}).get(name, {}).get('file')
            target = entry.get('target', name)
            if not isinstance(source, str) or not source.startswith('/') or not isinstance(target, str):
                raise MigrationError('secretファイル参照が不明です')
            target = target if target.startswith('/') else '/run/secrets/' + target
            if target == '/config' or target in mounts:
                raise MigrationError('secretターゲットが不正です')
            mounts[target] = {'type': 'bind', 'source': source, 'rw': False}
        for target, name in EXTERNAL_MOUNTS.get(role, {}).items():
            if mounts.get(target, {}).get('source') != name or mounts[target]['type'] != 'volume':
                raise MigrationError('必要な既存volumeがありません')
        result[role] = mounts
    if services['edge'].get('environment', {}).get('XDG_CONFIG_HOME') != '/caddy-config':
        raise MigrationError('Caddyの設定ディレクトリが一致しません')
    for role, port in (('edge', 8443), ('ops', 8790)):
        ports = services[role].get('ports', [])
        if len(ports) != 1:
            raise MigrationError('移行用port設定が一致しません')
        entry = ports[0]
        valid = (entry == f'{port}:{port}' or isinstance(entry, dict)
                 and str(entry.get('published')) == str(port) and entry.get('target') == port
                 and entry.get('protocol', 'tcp') == 'tcp')
        if not valid:
            raise MigrationError('移行用port設定が一致しません')
    return result


def check_mounts(item, expected):
    actual = {}
    for mount in item.get('Mounts', []):
        if mount.get('Type') == 'tmpfs':
            continue
        target = mount.get('Destination')
        source = mount.get('Name') if mount.get('Type') == 'volume' else mount.get('Source')
        if (target == '/config' or target in actual or not isinstance(source, str)
                or source.startswith('/tmp/casaos-compose-app-')
                or re.fullmatch(r'/DATA/AppData/[^/]+/config', source)):
            raise MigrationError('ZimaOSによる想定外のmount書換えを検出しました')
        actual[target] = {'type': mount.get('Type'), 'source': source, 'rw': mount.get('RW')}
    if actual != expected:
        raise MigrationError('実コンテナのmountがcomposeと一致しません')


def healthy(item):
    return (item.get('State', {}).get('Running') is True
            and item.get('State', {}).get('Health', {}).get('Status') == 'healthy')


class Host:
    def run(self, args, timeout=60, allow_failure=False):
        try:
            result = subprocess.run(args, capture_output=True, timeout=timeout, check=False)
        except (OSError, subprocess.SubprocessError):
            raise MigrationError('ホストコマンドを実行できません（詳細は非表示）') from None
        if result.returncode and not allow_failure:
            raise MigrationError('ホストコマンドが失敗しました（詳細は非表示）')
        return result

    def docker(self, *args, timeout=60):
        return self.run(['docker', *args], timeout)

    def inspect(self, name):
        result = self.run(['docker', 'inspect', '--type', 'container', name], allow_failure=True)
        if result.returncode:
            self.docker('info', '--format', '{{json .ServerVersion}}')
            return None
        try:
            items = json.loads(result.stdout)
            if len(items) != 1 or not isinstance(items[0], dict):
                raise ValueError
            return items[0]
        except (ValueError, TypeError):
            raise MigrationError('Docker inspectの形式が不明です') from None

    def compose(self, path):
        args = ['compose', '--env-file', '/dev/null', '-f', str(path), 'config']
        self.docker(*args, '-q')
        try:
            return json.loads(self.docker(*args, '--format', 'json').stdout)
        except ValueError:
            raise MigrationError('Compose JSONを取得できません') from None

    def probe(self, url, expected, insecure=False, svg=False):
        args = ['curl', '--silent', '--show-error', '--noproxy', '*', '--max-time', '20',
                '--output', '/dev/null', '--write-out', '%{http_code}|%{content_type}']
        if insecure:
            args.append('--insecure')
        if url in (PUBLIC_URL, LOCAL_URL):
            args += ['--header', 'x-fuminiwa-client-version: 0.1.0']
        result = self.run(args + [url], timeout=25)
        code, _, content_type = result.stdout.decode('ascii', errors='replace').partition('|')
        if code != str(expected) or (svg and not content_type.startswith('image/svg+xml')):
            raise MigrationError('HTTP受入確認が失敗しました')

    def backup(self):
        before = self.docker('exec', NAMES['ops'], 'cat', '/backups/last-success.json').stdout
        self.docker('exec', NAMES['ops'], 'run-backup', timeout=3600)
        after = self.docker('exec', NAMES['ops'], 'cat', '/backups/last-success.json').stdout
        try:
            record = json.loads(after)
            stamp = dt.datetime.fromisoformat(record['completed_at'])
            age = (dt.datetime.now(dt.timezone.utc) - stamp).total_seconds()
            if before == after or not 0 <= age < 300 or not record.get('backup'):
                raise ValueError
        except (ValueError, KeyError, TypeError):
            raise MigrationError('backup成功記録の更新を確認できません') from None


class Journal:
    def __init__(self, path):
        self.path = Path(path)

    @contextlib.contextmanager
    def locked(self):
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = self.path.parent.stat()
        if info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise MigrationError('移行記録の保存先は本人所有・他者書込不可にしてください')
        fd = os.open(str(self.path) + '.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.getuid():
                raise MigrationError('移行lockは本人所有の0600にしてください')
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise MigrationError('別の移行が実行中です') from None
            yield
        finally:
            os.close(fd)

    def read(self):
        if not os.path.lexists(self.path):
            return None
        fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, 'r', encoding='utf-8') as source:
            info = os.fstat(source.fileno())
            if stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode):
                raise MigrationError('移行記録は本人所有の0600にしてください')
            value = json.load(source)
        if (value.get('phase') not in ('armed', 'success', 'rolled-back', 'rollback-incomplete')
                or set(value.get('old_ids', {})) != set(NAMES)
                or any(not re.fullmatch(r'[0-9a-f]{64}', v) for v in value['old_ids'].values())):
            raise MigrationError('移行記録の形式が不正です')
        return value

    def save(self, record):
        path = None
        try:
            fd, path = tempfile.mkstemp(prefix='.migration-', dir=self.path.parent)
            with os.fdopen(fd, 'w') as destination:
                json.dump(record, destination)
                destination.flush()
                os.fsync(destination.fileno())
            os.replace(path, self.path)
            directory = os.open(self.path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if path and os.path.exists(path):
                os.unlink(path)


class Migration:
    def __init__(self, client, host, journal, sleep=time.sleep, clock=time.monotonic):
        self.client, self.host, self.journal = client, host, journal
        self.sleep, self.clock = sleep, clock
        self.record = None

    def wait(self, predicate, message, timeout=300):
        deadline = self.clock() + timeout
        while True:
            if predicate():
                return
            if self.clock() >= deadline:
                raise MigrationError(message)
            self.sleep(2)

    def app_id(self):
        ids = {value for name in NAMES.values() if (value := self.client.find(name)) is not None}
        if len(ids) > 1:
            raise MigrationError('移行対象のアプリidを一意に特定できません')
        return next(iter(ids), None)

    def preflight(self, compose):
        registry = self.host.inspect('fuminiwa-registry')
        if not registry or not registry.get('State', {}).get('Running'):
            raise MigrationError('レジストリが稼働していません')
        document = self.host.compose(compose)
        expected = expected_mounts(document)
        self.client.access()
        old = {}
        for role, name in NAMES.items():
            item = self.host.inspect(name)
            if not item or not item.get('State', {}).get('Running'):
                raise MigrationError('旧4コンテナが稼働していません')
            if self.host.inspect(name + '-legacy') or self.host.inspect(name + '-zimaos-failed'):
                raise MigrationError('退避コンテナが既に存在します。前回の作業を確認してください')
            if not re.fullmatch(r'[0-9a-f]{64}', item.get('Id', '')):
                raise MigrationError('旧コンテナのIDが不明です')
            old[role] = item
        if self.app_id() is not None:
            raise MigrationError('同じcontainer_nameのZimaOSアプリが既にあります')
        return old, expected

    def accept(self, expected, old_server_image=None):
        self.wait(lambda: all(self.host.inspect(name) for name in NAMES.values()), '新4コンテナの出現待ちが期限を超えました')
        # Check every mount before waiting for health; wrong DB must not pass.
        for role, name in NAMES.items():
            item = self.host.inspect(name)
            check_mounts(item, expected[role])
            if item.get('HostConfig', {}).get('RestartPolicy', {}).get('Name') != 'unless-stopped':
                raise MigrationError('新コンテナのrestart設定が一致しません')
            if role == 'server' and old_server_image and item.get('Image') != old_server_image:
                raise MigrationError('移行でserver imageが変わっています')
        self.wait(lambda: all(healthy(self.host.inspect(n) or {}) for n in NAMES.values()), 'health待ちが5分を超えました')
        self.host.probe(LOCAL_URL, 200, insecure=True)
        self.host.probe(PUBLIC_URL, 200)
        self.host.probe('http://127.0.0.1:8790/', 401)
        self.host.probe('http://127.0.0.1:8790/icon.svg', 200, svg=True)

    def rollback(self):
        record = self.record
        # Validate legacy identities before changing any new/old container.
        for role, name in NAMES.items():
            legacy = self.host.inspect(name + '-legacy')
            current = self.host.inspect(name)
            if legacy and legacy['Id'] != record['old_ids'][role]:
                raise MigrationError('legacyのIDが一致しません。自動復旧を中止します')
            if not legacy and (not current or current['Id'] != record['old_ids'][role]):
                raise MigrationError('旧コンテナが見つかりません。自動復旧を中止します')
        # Once any original has been restored, do not ask an uncertain app
        # manager to delete by the original names again. Resume by ID only.
        already_restoring = any((item := self.host.inspect(name)) and item['Id'] == record['old_ids'][role]
                                for role, name in NAMES.items())
        api_ok = record.get('api_cleanup_ok', True)
        if record.get('install_attempted') and already_restoring:
            api_ok = record.get('api_cleanup_ok', False)
        if record.get('install_attempted') and not already_restoring and not record.get('api_cleanup_ok'):
            try:
                app_id = self.app_id() or record.get('app_id')
                if app_id:
                    app_path(app_id)
                    self.client.uninstall(app_id)
                    try:
                        self.wait(lambda: all(identity != app_id for identity, _ in self.client.apps()),
                                  'アプリ削除を確認できません', timeout=60)
                    except AppError:
                        api_ok = False
                    try:
                        self.wait(lambda: all(not self.host.inspect(n) or self.host.inspect(n)['Id'] == record['old_ids'][r]
                                              for r, n in NAMES.items()), '新コンテナが残っています', timeout=60)
                    except MigrationError:
                        pass  # Preserve leftovers by renaming, never deleting.
            except AppError:
                api_ok = False
        record['api_cleanup_ok'] = api_ok
        self.journal.save(record)
        for role, name in NAMES.items():
            item = self.host.inspect(name)
            if item and item['Id'] != record['old_ids'][role]:
                if self.host.inspect(name + '-zimaos-failed'):
                    raise MigrationError('failed退避名が使用中です。自動復旧を中止します')
                self.host.docker('update', '--restart', 'no', item['Id'])
                self.host.docker('stop', '--time', '120' if role == 'postgres' else '30', item['Id'], timeout=150)
                self.host.docker('rename', item['Id'], name + '-zimaos-failed')
            legacy = self.host.inspect(name + '-legacy')
            if legacy:
                self.host.docker('rename', legacy['Id'], name)
            self.host.docker('update', '--restart', 'unless-stopped', record['old_ids'][role])
        self.host.docker('start', record['old_ids']['postgres'])
        self.wait(lambda: healthy(self.host.inspect(NAMES['postgres']) or {}), '旧postgresのhealth復旧が期限を超えました')
        self.host.docker('start', record['old_ids']['server'])
        self.wait(lambda: healthy(self.host.inspect(NAMES['server']) or {}), '旧serverのhealth復旧が期限を超えました')
        self.host.docker('start', record['old_ids']['edge'], record['old_ids']['ops'])
        self.wait(lambda: all(healthy(self.host.inspect(n) or {}) for n in NAMES.values()), '旧4コンテナのhealth復旧が期限を超えました')
        self.host.probe(PUBLIC_URL, 200)
        record['phase'] = 'rolled-back' if api_ok else 'rollback-incomplete'
        self.journal.save(record)
        if not api_ok:
            raise MigrationError('旧構成は復旧しましたがAPI削除を確認できません。アプリ管理の確認が必要です')

    def execute(self, compose):
        with self.journal.locked():
            self.record = self.journal.read()
            if self.record and self.record['phase'] in ('armed', 'rollback-incomplete'):
                self.rollback()
                raise MigrationError('中断した移行を旧構成へ戻しました。再実行前に原因を確認してください')
            if self.record and self.record['phase'] == 'rolled-back':
                raise MigrationError('前回は切戻し済みです。退避・アプリを確認後、移行記録を退避して再実行してください')
            # Snapshot once. Install exactly the bytes whose mounts we validated.
            contents = Path(compose).read_bytes()
            with tempfile.TemporaryDirectory(prefix='.zimaos-migrate-', dir=self.journal.path.parent) as temporary:
                snapshot = Path(temporary) / 'compose.yml'
                snapshot.write_bytes(contents)
                snapshot.chmod(0o600)
                if self.record and self.record['phase'] == 'success':
                    if self.record['compose_sha256'] != hashlib.sha256(contents).hexdigest():
                        raise MigrationError('移行済みです。更新はapplyを使ってください')
                    self.accept(expected_mounts(self.host.compose(snapshot)), self.record['server_image'])
                    print('移行済みの構成を確認しました（legacyは保持）')
                    return
                old, expected = self.preflight(snapshot)
                print('前提確認成功。旧opsでバックアップを実行します')
                self.host.backup()
                self.record = {'phase': 'armed', 'old_ids': {r: v['Id'] for r, v in old.items()},
                               'server_image': old['server']['Image'], 'install_attempted': False,
                               'compose_sha256': hashlib.sha256(contents).hexdigest()}
                self.journal.save(self.record)  # Crash recovery starts before first stop.
                try:
                    for role in ('ops', 'edge', 'server', 'postgres'):
                        seconds = '120' if role == 'postgres' else '30'
                        self.host.docker('stop', '--time', seconds, old[role]['Id'], timeout=150)
                    for role, name in NAMES.items():
                        self.host.docker('update', '--restart', 'no', old[role]['Id'])
                        self.host.docker('rename', old[role]['Id'], name + '-legacy')
                    self.record['install_attempted'] = True
                    self.journal.save(self.record)
                    self.client.install(snapshot)
                    self.accept(expected, self.record['server_image'])
                    app_id = self.app_id()
                    if not app_id:
                        raise MigrationError('インストール後のアプリidを確認できません')
                    self.record.update(phase='success', app_id=app_id)
                    self.journal.save(self.record)
                    print('移行成功。旧4コンテナは-legacyで保持しています')
                except (Exception, KeyboardInterrupt) as error:
                    reason = str(error) if isinstance(error, AppError) else '移行処理が中断／失敗しました（詳細は非表示）'
                    print('移行失敗: ' + reason + '。旧構成へ戻します')
                    try:
                        self.rollback()
                    except (Exception, KeyboardInterrupt):
                        self.record['phase'] = 'rollback-incomplete'
                        self.journal.save(self.record)
                        raise MigrationError('自動ロールバックが完了していません。移行記録とコンテナを確認してください') from None
                    raise MigrationError('移行は失敗しました。旧構成のhealthと公開200は復旧しました') from None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compose')
    parser.add_argument('--token-file', default=DEFAULT_TOKEN)
    parser.add_argument('--state-file', default=DEFAULT_STATE)
    args = parser.parse_args(argv)
    os.umask(0o077)
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    try:
        Migration(Client(TokenStore(args.token_file)), Host(), Journal(args.state_file)).execute(args.compose)
        return 0
    except AppError as error:
        print(str(error))
    except (Exception, KeyboardInterrupt):
        print('移行に失敗しました（詳細は非表示）。移行記録を確認してください')
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
