"""All transports are fakes: no login, Docker daemon or network is contacted."""
import contextlib
import copy
import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[2] / 'SyncServerV2/zimaos'
sys.path.insert(0, str(HERE))
import zimaos_app as app
import migrate_app as migrate
spec = importlib.util.spec_from_file_location('zimaos_fixture', Path(__file__).with_name('test_zimaos.py'))
fixture_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture_module)

ACCESS = 'test-access-secret'
REFRESH = 'test-refresh-secret'


def record(expires=10000):
    return {'access_token': ACCESS, 'refresh_token': REFRESH, 'expires_at': expires,
            'saved_at': 1, 'username': 'recky'}


class FakeHTTP:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def __call__(self, request):
        self.requests.append(request)
        value = self.responses.pop(0)
        if isinstance(value, Exception):
            raise value
        status, payload = value
        return status, json.dumps(payload).encode()


class APITests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / 'token.json'
        self.store = app.TokenStore(self.path)
        with self.store.locked():
            self.store.save(record())

    def client(self, replies, now=1000):
        transport = FakeHTTP(replies)
        return app.Client(self.store, transport=transport, clock=lambda: now), transport

    def test_existing_format_permission_and_atomic_replace(self):
        self.assertEqual(self.store.read(), record())
        inode = self.path.stat().st_ino
        with self.store.locked():
            self.store.save(record(20000))
        self.assertNotEqual(self.path.stat().st_ino, inode)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(set(json.loads(self.path.read_text())), set(record()))
        self.assertEqual(list(self.path.parent.glob('.zimaos-token-*')), [])
        for mode in (0o644, 0o400, 0o660, 0o700):
            self.path.chmod(mode)
            with self.assertRaises(app.AppError):
                self.store.read()
        self.path.chmod(0o600)
        link = self.path.with_name('link.json')
        link.symlink_to(self.path)
        with self.assertRaises(app.AppError):
            app.TokenStore(link).read()

    def test_expiry_margin_and_refresh_rotation(self):
        client, http = self.client([])
        self.assertEqual(client.access(), ACCESS)
        self.assertFalse(http.requests)
        self.store.save(record(1300))  # Equality at the five-minute margin refreshes.
        client, http = self.client([(200, {'data': {'token': {
            'access_token': 'next-access', 'refresh_token': 'next-refresh', 'expires_at': 20000}}})])
        self.assertEqual(client.access(), 'next-access')
        self.assertEqual(json.loads(http.requests[0].data), {'refresh_token': REFRESH})
        replacement = self.store.read()
        self.assertEqual(replacement['refresh_token'], 'next-refresh')
        self.assertEqual(replacement['username'], 'recky')
        self.assertEqual(replacement['expires_at'], 20000)
        self.assertFalse(client.access() == ACCESS)
        self.assertEqual(len(http.requests), 1)

    def test_login_compatible_response_and_no_password_saved(self):
        client, http = self.client([(200, {'data': {'token': record()}})])
        with patch.object(app, 'Client', return_value=client), patch('builtins.input', return_value='recky'), patch.object(app.getpass, 'getpass', return_value='my-password'):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(app.main(['--token-file', str(self.path), 'login']), 0)
        self.assertEqual(output.getvalue(), '保存しました\n')
        self.assertNotIn('my-password', self.path.read_text())
        self.assertEqual(json.loads(http.requests[0].data)['password'], 'my-password')

    def test_failed_refresh_requests_relogin_and_preserves_file(self):
        self.store.save(record(1001))
        for response in ((401, {'message': ACCESS + REFRESH}), (200, {'unexpected': ACCESS}), RuntimeError(ACCESS)):
            client, http = self.client([response])
            with self.assertRaises(app.AppError) as caught:
                client.access()
            self.assertIn(app.LOGIN_HINT, str(caught.exception))
            self.assertNotIn(ACCESS, str(caught.exception))
            self.assertEqual(self.store.read()['refresh_token'], REFRESH)
            self.assertEqual(len(http.requests), 1)

    def test_authorization_fallback_once_and_errors_never_echo_credentials(self):
        client, http = self.client([(401, {'message': 'Unauthorized'}), (200, {'data': {}})])
        self.assertEqual(client.apps(), [])
        self.assertEqual([r.get_header('Authorization') for r in http.requests], [ACCESS, 'Bearer ' + ACCESS])
        client, http = self.client([(401, {'message': ACCESS}), (401, {'message': 'Authorization: ' + REFRESH, 'data': {'token': record()}})])
        with self.assertRaises(app.APIError) as caught:
            client.apps()
        self.assertIn('HTTP 401', str(caught.exception))
        self.assertNotIn(ACCESS, str(caught.exception))
        self.assertNotIn(REFRESH, str(caught.exception))
        self.assertEqual(len(http.requests), 2)
        client, _ = self.client([RuntimeError('Authorization: ' + ACCESS)])
        with self.assertRaises(app.AppError) as caught:
            client.apps()
        self.assertNotIn(ACCESS, str(caught.exception))

    def test_loopback_only_no_redirect_and_no_proxy(self):
        for url in ('http://192.168.11.5', 'https://127.0.0.1', 'http://localhost',
                    'http://127.0.0.1.evil', 'http://127.0.0.1@evil', 'http://user@127.0.0.1',
                    'http://[::1]', 'http://127.0.0.1/x', 'http://127.0.0.1?secret=x'):
            with self.subTest(url=url), self.assertRaises(app.AppError):
                app.Client(self.store, base=url)
        self.assertIsNotNone(app.Client(self.store, base='http://127.0.0.1:80'))
        self.assertIsNone(app.NoRedirect().redirect_request(None, None, 302, '', {}, 'http://evil'))
        with patch.object(app.urllib.request, 'build_opener') as build:
            build.return_value.open.side_effect = OSError(ACCESS)
            with self.assertRaises(app.AppError):
                app.Client.http(None)
            self.assertEqual(build.call_args.args[0].proxies, {})

    def test_install_dry_run_and_delete_keep_config_and_apply(self):
        compose = self.path.with_name('compose.yml')
        compose.write_text('services: {}\n')
        client, http = self.client([(200, {}), (202, {}), (200, {}), (200, {})])
        client.install(compose)
        client.uninstall('sample_app')
        client.apply('sample_app', compose)
        self.assertEqual([r.method for r in http.requests], ['POST', 'POST', 'DELETE', 'PUT'])
        self.assertTrue(http.requests[0].full_url.endswith('?dry_run=true&check_port_conflict=true'))
        self.assertTrue(http.requests[1].full_url.endswith('?dry_run=false&check_port_conflict=true'))
        self.assertTrue(http.requests[2].full_url.endswith('?delete_config_folder=false'))
        self.assertEqual(http.requests[0].get_header('Content-type'), 'application/yaml')
        self.assertEqual(http.requests[0].data, compose.read_bytes())
        client, http = self.client([(200, {})])
        client.install(compose, dry_run=True)
        self.assertEqual(len(http.requests), 1)
        client, http = self.client([(400, {'message': 'body ' + ACCESS})])
        with self.assertRaises(app.APIError):
            client.install(compose)
        self.assertEqual(len(http.requests), 1)
        for bad_id in ('../x', '/x', 'x?delete_config_folder=true', ''):
            with self.assertRaises(app.AppError):
                app.app_path(bad_id)

    def test_find_and_status_use_only_metadata(self):
        name = migrate.NAMES['server']
        client, http = self.client([(200, {'data': {'sample': {'title': {'ja_JP': 'ふみにわ'}}}}),
                                    (200, {'data': [{'Name': '/' + name}]})])
        self.assertEqual(client.find(name), 'sample')
        client, _ = self.client([(200, {'data': {'title': 'ふみにわ', 'state': 'running', 'environment': {'PASSWORD': REFRESH}}}),
                                 (200, {'data': [{'Name': '/' + name, 'State': {'Status': 'running'}, 'Env': [REFRESH]}]}),
                                 (200, {'data': {'status': 'healthy', 'output': ACCESS}})])
        summary = json.dumps(client.status('sample'))
        self.assertNotIn(ACCESS, summary)
        self.assertNotIn(REFRESH, summary)
        client, _ = self.client([(200, {'data': {'one': {'container_name': name}, 'two': {'container_name': name}}})])
        with self.assertRaises(app.AppError):
            client.find(name)
        self.assertTrue(app.contains_container('  "container_name": "' + name + '"\n', name))

    def test_lock_prevents_refresh_race_and_preserves_old_on_save_failure(self):
        with self.store.locked():
            fd = os.open(str(self.path) + '.lock', os.O_RDWR)
            try:
                with self.assertRaises(BlockingIOError):
                    app.fcntl.flock(fd, app.fcntl.LOCK_EX | app.fcntl.LOCK_NB)
            finally:
                os.close(fd)
        contents = self.path.read_bytes()
        with patch.object(app.os, 'replace', side_effect=OSError('secret')):
            with self.assertRaises(app.AppError):
                self.store.save(record(20000))
        self.assertEqual(self.path.read_bytes(), contents)
        self.assertFalse(list(self.path.parent.glob('.zimaos-token-*')))

    def test_cli_errors_and_metadata_do_not_expose_authorization_or_tokens(self):
        client, _ = self.client([(200, {'data': {'sample': {'title': ACCESS + REFRESH, 'state': 'running', 'Env': [ACCESS]}}})])
        output = io.StringIO()
        with patch.object(app, 'Client', return_value=client), contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            self.assertEqual(app.main(['list']), 0)
        self.assertNotIn(ACCESS, output.getvalue())
        self.assertNotIn(REFRESH, output.getvalue())
        client, _ = self.client([(500, {'message': 'Authorization: ' + ACCESS, 'data': {'refresh_token': REFRESH}})])
        output = io.StringIO()
        with patch.object(app, 'Client', return_value=client), contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            self.assertEqual(app.main(['list']), 1)
        self.assertIn('HTTP 500', output.getvalue())
        self.assertNotIn('Authorization', output.getvalue())
        self.assertNotIn(ACCESS, output.getvalue())
        self.assertNotIn(REFRESH, output.getvalue())
        client, _ = self.client([(200, {'data': {'a' * 64: {'container_name': migrate.NAMES['server']}}})])
        output = io.StringIO()
        with patch.object(app, 'Client', return_value=client), contextlib.redirect_stdout(output):
            self.assertEqual(app.main(['find', '--container', migrate.NAMES['server']]), 0)
        self.assertEqual(output.getvalue().strip(), 'a' * 64)
        self.assertTrue(app.contains_container(json.dumps({'services': {'server': {'container_name': migrate.NAMES['server']}}}), migrate.NAMES['server']))


def normalized_compose():
    items, images = fixture_module.fixture()
    document = fixture_module.render.render(items, images, fixture_module.SERVER_REF,
        fixture_module.OPS_REF, fixture_module.render.BASE + '/ops/ops-ui-password',
        '/DATA/AppData/fuminiwa-sync/config/Caddyfile', '192.168.11.5', 8790)
    for service in document['services'].values():
        volumes = []
        for entry in service.get('volumes', []):
            if isinstance(entry, str):
                source, target, *mode = entry.split(':')
                entry = {'type': 'volume', 'source': source, 'target': target, 'read_only': mode == ['ro']}
            volumes.append(entry)
        service['volumes'] = volumes
        service['secrets'] = [{'source': entry, 'target': entry} for entry in service.get('secrets', [])]
    return document


class FakeHost:
    def __init__(self, document):
        self.document = document
        self.calls = []
        self.probes = []
        self.mount_fault = False
        self.health_fault = False
        self.stop_fault = None
        self.http_fault = False
        self.items = {}
        self.counter = 0
        self.expected = migrate.expected_mounts(document)
        for index, (role, name) in enumerate(migrate.NAMES.items(), 1):
            self.items[name] = self.item(role, f'{index:064x}')
        self.items['fuminiwa-registry'] = {'State': {'Running': True}}

    def item(self, role, identity):
        return {'Id': identity, 'Image': 'sha256:server-image',
                'State': {'Running': True, 'Health': {'Status': 'healthy'}},
                'HostConfig': {'RestartPolicy': {'Name': 'unless-stopped'}},
                'Mounts': [{'Type': mount['type'], 'Destination': target, 'RW': mount['rw'],
                            'Name' if mount['type'] == 'volume' else 'Source': mount['source']}
                           for target, mount in self.expected[role].items()]}

    def inspect(self, name):
        return copy.deepcopy(self.items.get(name))

    def compose(self, path):
        self.calls.append(('compose', str(path)))
        return copy.deepcopy(self.document)

    def docker(self, *args, **kwargs):
        self.calls.append(args)
        if args[0] in ('stop', 'start', 'rename', 'update'):
            identity = args[-2] if args[0] == 'rename' else args[-1]
            if args[0] == 'start':
                ids = args[1:]
            else:
                ids = [identity]
            for identity in ids:
                name, item = next((n, i) for n, i in self.items.items() if i.get('Id') == identity)
                if args[0] == 'stop':
                    if self.stop_fault == name:
                        self.stop_fault = None
                        raise migrate.MigrationError('fake stop failure')
                    item['State']['Running'] = False
                elif args[0] == 'start':
                    item['State']['Running'] = True
                elif args[0] == 'rename':
                    self.items[args[-1]] = self.items.pop(name)
                else:
                    item['HostConfig']['RestartPolicy']['Name'] = args[2]
        return subprocess.CompletedProcess(args, 0, b'', b'')

    def backup(self):
        self.calls.append(('backup',))

    def probe(self, url, expected, **kwargs):
        self.probes.append((url, expected, kwargs))
        if self.http_fault and url == migrate.PUBLIC_URL:
            self.http_fault = False
            raise migrate.MigrationError('fake public failure')

    def install(self):
        for index, (role, name) in enumerate(migrate.NAMES.items(), 100):
            item = self.item(role, f'{index:064x}')
            if self.mount_fault and role == 'postgres':
                item['Mounts'][0].update(Type='bind', Source='/tmp/casaos-compose-app-42/db')
            if self.health_fault:
                item['State']['Health']['Status'] = 'unhealthy'
            self.items[name] = item


class FakeClient:
    def __init__(self, host):
        self.host = host
        self.installed = False
        self.keep_containers = False
        self.install_fault = False
        self.delete_fault = False
        self.delete_still_listed = False
        self.calls = []

    def access(self):
        self.calls.append('access')
        return ACCESS

    def apps(self):
        return [('sample', {})] if self.installed else []

    def find(self, name):
        return 'sample' if self.installed else None

    def install(self, path):
        self.calls.append('install')
        self.installed = True
        self.host.install()
        if self.install_fault:
            raise app.APIError(500, {'message': ACCESS})

    def uninstall(self, app_id):
        self.calls.append(('uninstall', app_id))
        if self.delete_fault:
            raise app.APIError(500)
        self.installed = self.delete_still_listed
        if not self.keep_containers:
            for name in migrate.NAMES.values():
                self.host.items.pop(name, None)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.compose = self.root / 'compose.yml'
        self.compose.write_text('fake compose')
        self.document = normalized_compose()
        self.host = FakeHost(self.document)
        self.client = FakeClient(self.host)
        self.journal = migrate.Journal(self.root / 'migration.json')
        self.tick = 0
        def clock():
            self.tick += 100
            return self.tick
        self.engine = migrate.Migration(self.client, self.host, self.journal, sleep=lambda _: None, clock=clock)
        self.old_ids = {r: self.host.items[n]['Id'] for r, n in migrate.NAMES.items()}

    def execute(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.engine.execute(self.compose)
        return output.getvalue()

    def assert_restored(self):
        for role, name in migrate.NAMES.items():
            item = self.host.items[name]
            self.assertEqual(item['Id'], self.old_ids[role])
            self.assertTrue(migrate.healthy(item))
            self.assertEqual(item['HostConfig']['RestartPolicy']['Name'], 'unless-stopped')
            self.assertNotIn(name + '-legacy', self.host.items)

    def test_success_order_legacy_mounts_probes_and_idempotence(self):
        self.execute()
        self.assertEqual(self.journal.read()['phase'], 'success')
        stops = [call for call in self.host.calls if call[0] == 'stop']
        self.assertEqual([call[-1] for call in stops], [self.old_ids[r] for r in ('ops', 'edge', 'server', 'postgres')])
        self.assertEqual([call[2] for call in stops], ['30', '30', '30', '120'])
        self.assertLess(self.host.calls.index(('backup',)), self.host.calls.index(stops[0]))
        for role, name in migrate.NAMES.items():
            legacy = self.host.items[name + '-legacy']
            self.assertFalse(legacy['State']['Running'])
            self.assertEqual(legacy['HostConfig']['RestartPolicy']['Name'], 'no')
            self.assertEqual(legacy['Id'], self.old_ids[role])
        self.assertEqual([p[1] for p in self.host.probes], [200, 200, 401, 200])
        self.assertTrue(self.host.probes[0][2]['insecure'])
        self.assertTrue(self.host.probes[-1][2]['svg'])
        before = list(self.client.calls)
        self.execute()
        self.assertEqual(self.client.calls, before)
        self.assertEqual(sum(c == ('backup',) for c in self.host.calls), 1)
        self.assertFalse(any(c[0] in ('rm', 'down') for c in self.host.calls))

    def test_preflight_failure_never_stops_or_backups(self):
        for fault in ('registry', 'legacy', 'app', 'stopped', 'volumes', 'ports'):
            with self.subTest(fault=fault):
                self.setUp()
                if fault == 'registry':
                    self.host.items['fuminiwa-registry']['State']['Running'] = False
                elif fault == 'legacy':
                    self.host.items[migrate.NAMES['server'] + '-legacy'] = self.host.item('server', 'a' * 64)
                elif fault == 'app':
                    self.client.installed = True
                elif fault == 'stopped':
                    self.host.items[migrate.NAMES['server']]['State']['Running'] = False
                elif fault == 'volumes':
                    self.host.document['volumes'] = {}
                else:
                    self.host.document['services']['ops']['ports'] = ['9999:8790']
                with self.assertRaises(app.AppError):
                    self.execute()
                self.assertFalse(any(c[0] in ('backup', 'stop', 'rename', 'update') for c in self.host.calls))

    def test_mount_rewrite_health_install_or_public_failure_rolls_back(self):
        for fault in ('mount_fault', 'health_fault', 'install_fault', 'http_fault'):
            with self.subTest(fault=fault):
                self.setUp()
                setattr(self.client if fault == 'install_fault' else self.host, fault, True)
                with self.assertRaises(migrate.MigrationError):
                    self.execute()
                self.assert_restored()
                self.assertEqual(self.journal.read()['phase'], 'rolled-back')
                self.assertIn(('uninstall', 'sample'), self.client.calls)
                self.assertEqual(self.host.probes[-1][:2], (migrate.PUBLIC_URL, 200))

    def test_partial_stop_failure_restores_even_before_install(self):
        self.host.stop_fault = migrate.NAMES['server']
        with self.assertRaises(migrate.MigrationError):
            self.execute()
        self.assert_restored()
        self.assertNotIn('install', self.client.calls)
        self.assertFalse(any(isinstance(c, tuple) and c[0] == 'uninstall' for c in self.client.calls))

    def test_leftovers_are_stopped_and_renamed_never_deleted(self):
        self.client.keep_containers = True
        self.host.mount_fault = True
        with self.assertRaises(migrate.MigrationError):
            self.execute()
        self.assert_restored()
        for name in migrate.NAMES.values():
            failed = self.host.items[name + '-zimaos-failed']
            self.assertFalse(failed['State']['Running'])
            self.assertEqual(failed['HostConfig']['RestartPolicy']['Name'], 'no')
        self.assertFalse(any(c[0] == 'rm' for c in self.host.calls))

    def test_uninstall_failure_recovers_old_but_reports_incomplete(self):
        self.client.delete_fault = True
        self.client.install_fault = True
        with self.assertRaises(migrate.MigrationError):
            self.execute()
        self.assert_restored()
        self.assertEqual(self.journal.read()['phase'], 'rollback-incomplete')

    def test_delete_acknowledgment_without_app_disappearance_is_incomplete(self):
        self.client.install_fault = True
        self.client.delete_still_listed = True
        with self.assertRaises(migrate.MigrationError):
            self.execute()
        self.assert_restored()
        self.assertEqual(self.journal.read()['phase'], 'rollback-incomplete')

    def test_interrupted_journal_recovers_by_id_and_rejects_wrong_legacy(self):
        old, _ = self.engine.preflight(self.compose)
        self.engine.record = {'phase': 'armed', 'old_ids': self.old_ids, 'install_attempted': False}
        self.journal.save(self.engine.record)
        role = 'server'
        self.host.docker('stop', '--time', '30', old[role]['Id'])
        self.host.docker('rename', old[role]['Id'], migrate.NAMES[role] + '-legacy')
        with self.assertRaises(migrate.MigrationError):
            self.execute()
        self.assert_restored()
        self.assertEqual(self.journal.read()['phase'], 'rolled-back')
        # A stale/foreign legacy ID must be rejected before any uninstall/stop.
        self.engine.record['phase'] = 'armed'
        self.engine.record['install_attempted'] = True
        self.journal.save(self.engine.record)
        self.host.items[migrate.NAMES[role] + '-legacy'] = self.host.item(role, 'b' * 64)
        count = len(self.host.calls)
        with self.assertRaises(migrate.MigrationError):
            self.execute()
        self.assertEqual(len(self.host.calls), count)
        self.assertNotIn(('uninstall', 'sample'), self.client.calls)

    def test_mount_contract_catches_both_real_incidents_and_permissions(self):
        role = 'edge'
        expected = self.host.expected[role]
        item = self.host.item(role, 'a' * 64)
        migrate.check_mounts(item, expected)  # Caddyfile under fuminiwa-sync/config is legitimate.
        for source, target in (('/tmp/casaos-compose-app-7/caddy-data', '/data'),
                               ('/DATA/AppData/postgres/config', '/caddy-config'),
                               ('/DATA/AppData/postgres/config', '/config')):
            broken = copy.deepcopy(item)
            broken['Mounts'][0] = {'Type': 'bind', 'Source': source, 'Destination': target, 'RW': True}
            with self.assertRaises(migrate.MigrationError):
                migrate.check_mounts(broken, expected)
        broken = copy.deepcopy(item)
        broken['Mounts'][-1]['RW'] = True
        with self.assertRaises(migrate.MigrationError):
            migrate.check_mounts(broken, expected)
        broken = copy.deepcopy(item)
        broken['Mounts'].pop()
        with self.assertRaises(migrate.MigrationError):
            migrate.check_mounts(broken, expected)

    def test_journal_lock_and_no_sensitive_record(self):
        with self.journal.locked():
            with self.assertRaises(migrate.MigrationError):
                with self.journal.locked():
                    pass
        self.execute()
        self.assertEqual(self.journal.path.stat().st_mode & 0o777, 0o600)
        contents = self.journal.path.read_text()
        for secret in (ACCESS, REFRESH, 'environment', 'secrets'):
            self.assertNotIn(secret, contents)

    def test_resuming_partial_restore_never_uninstalls_original_names(self):
        self.execute()
        saved = self.journal.read()
        saved.update(phase='armed', api_cleanup_ok=True)
        self.journal.save(saved)
        # Simulate completed uninstall and an interruption after postgres restore.
        self.client.installed = False
        for role, name in migrate.NAMES.items():
            self.host.items.pop(name)
            if role == 'postgres':
                self.host.items[name] = self.host.items.pop(name + '-legacy')
        before = list(self.client.calls)
        with self.assertRaises(migrate.MigrationError):
            self.execute()
        self.assert_restored()
        self.assertEqual(self.client.calls, before)

    def test_backup_failure_and_invalid_token_do_not_stop_old_containers(self):
        for source, method in ((self.host, 'backup'), (self.client, 'access')):
            with patch.object(source, method, side_effect=migrate.MigrationError('fake failure')):
                with self.assertRaises(migrate.MigrationError):
                    self.execute()
            self.assertFalse(any(c[0] in ('stop', 'rename', 'update') for c in self.host.calls))
            self.assertIsNone(self.journal.read())

    def test_real_host_commands_are_captured_and_errors_are_hidden(self):
        host = migrate.Host()
        fake = subprocess.CompletedProcess([], 1, ACCESS.encode(), REFRESH.encode())
        with patch.object(migrate.subprocess, 'run', return_value=fake):
            with self.assertRaises(migrate.MigrationError) as caught:
                host.docker('stop', 'fake')
        self.assertNotIn(ACCESS, str(caught.exception))
        self.assertNotIn(REFRESH, str(caught.exception))
        with patch.object(host, 'run', return_value=subprocess.CompletedProcess([], 0, b'200|text/json', b'')) as run:
            host.probe(migrate.LOCAL_URL, 200, insecure=True)
            args = run.call_args.args[0]
            self.assertIn('--insecure', args)
            self.assertIn('x-fuminiwa-client-version: 0.1.0', args)
            self.assertNotIn('--location', args)
        now = dt.datetime.now(dt.timezone.utc).isoformat()
        results = [subprocess.CompletedProcess([], 0, b'old', b''), subprocess.CompletedProcess([], 0, b'', b''),
                   subprocess.CompletedProcess([], 0, json.dumps({'completed_at': now, 'backup': 'new'}).encode(), b'')]
        with patch.object(host, 'docker', side_effect=results):
            host.backup()
        with patch.object(host, 'docker', return_value=results[-1]):
            with self.assertRaises(migrate.MigrationError):
                host.backup()


if __name__ == '__main__':
    unittest.main()
