import base64
import fcntl
import http.client
import importlib.util
import json
from pathlib import Path
import re
import sys
import os
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'SyncServerV2/ops'))
import ops
import ops_web as web


class WebTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.password = b'private-test-password-456'
        self.env_secret = 'private-environment-value-789'
        self.entered, self.release = threading.Event(), threading.Event()
        self.calls = []
        def reader(*args):
            self.calls.append(args)
            if args[0] == 'inspect':
                return json.dumps([{'Config': {'Env': ['SECRET=' + self.env_secret]},
                                   'State': {'Status': 'running', 'StartedAt': '2026-10-03T00:00:00Z',
                                             'Health': {'Status': 'healthy', 'Log': [{'Output': self.env_secret}]}},
                                   'HostConfig': {'RestartPolicy': {'Name': 'unless-stopped'}}}]).encode()
            self.assertEqual(args[0], 'logs')
            self.assertEqual(args[1:3], ('--tail', '100'))
            return b'\x1b[32mready\x1b[0m\n' + self.password + b'\n' + self.env_secret.encode() + b'\nAuthorization: Bearer token\n-----BEGIN PRIVATE KEY-----\n'
        def runner(lock):
            self.entered.set()
            self.release.wait(5)
            self.assertFalse(lock.closed)
            return 0
        self.dashboard = web.Dashboard(self.password, self.root, reader, runner)
        self.server = web.make_server(('127.0.0.1', 0), self.dashboard)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval': .01}, daemon=True)
        self.thread.start()
        def cleanup():
            self.release.set()
            self.server.shutdown()
            self.server.server_close()
            self.thread.join(2)
        self.addCleanup(cleanup)
        self.auth = 'Basic ' + base64.b64encode(b'admin:' + self.password).decode()
        self.host = '127.0.0.1:' + str(self.server.server_port)

    def request(self, method='GET', path='/', auth=None, body=None, headers=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=2)
        values = headers.copy() if headers else {}
        if auth is not None:
            values['Authorization'] = auth
        connection.request(method, path, body=body, headers=values)
        response = connection.getresponse()
        result = response.status, dict(response.getheaders()), response.read()
        connection.close()
        return result

    def post(self, **changes):
        options = dict(method='POST', path='/backup', auth=self.auth,
                       body='token=' + self.dashboard.token,
                       headers={'Origin': 'http://' + self.host,
                                'Content-Type': 'application/x-www-form-urlencoded'})
        options.update(changes)
        return self.request(**options)

    def test_auth_and_no_secret_or_environment_response(self):
        for header in (None, 'Basic invalid', 'Bearer example',
                       'Basic ' + base64.b64encode(b'wrong:' + self.password).decode(),
                       'Basic ' + base64.b64encode(b'admin:wrong').decode()):
            self.assertEqual(self.request(auth=header)[0], 401)
        self.assertEqual(self.calls, [])
        status, headers, body = self.request(auth=self.auth)
        self.assertEqual(status, 200)
        self.assertEqual(headers['Cache-Control'], 'no-store')
        self.assertIn(b'frame-ancestors', headers['Content-Security-Policy'].encode())
        self.assertNotIn(self.password, body)
        self.assertNotIn(self.env_secret.encode(), body)
        self.assertNotIn(b'Authorization: Bearer', body)
        self.assertNotIn(b'PRIVATE KEY', body)
        self.assertNotIn(b'\x1b', body)
        self.assertIn(b'ready', body)
        self.assertEqual(len([args for args in self.calls if args[0] == 'inspect']), 5)

    def test_csrf_requires_exact_origin_host_and_only_token(self):
        for origin in (None, 'null', 'https://' + self.host, 'http://evil.test',
                       'http://admin@' + self.host, 'http://' + self.host + '/extra'):
            headers = {'Content-Type': 'application/x-www-form-urlencoded'}
            if origin:
                headers['Origin'] = origin
            self.assertEqual(self.post(headers=headers)[0], 403)
        for body in ('token=wrong', 'token=%C3%A9', 'token=' + self.dashboard.token + '&command=stop',
                     'token=' + self.dashboard.token + '&token=' + self.dashboard.token):
            self.assertEqual(self.post(body=body)[0], 403)
        self.assertFalse(self.entered.is_set())

    def test_backup_action_and_double_execution_prevention(self):
        self.assertEqual(self.post()[0], 303)
        self.assertTrue(self.entered.wait(1))
        self.assertEqual(self.post()[0], 409)
        with (self.root / '.lock').open('a') as lock:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertIn(b'disabled', self.request(auth=self.auth)[2])
        self.release.set()
        deadline = time.monotonic() + 2
        while self.dashboard.running and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertFalse(self.dashboard.running)
        self.assertEqual(self.dashboard.result, '成功')

    def test_cli_or_cron_lock_prevents_web_run(self):
        with (self.root / '.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.post()[0], 409)
            self.assertFalse(self.entered.is_set())

    def test_no_other_commands_download_or_mutation_endpoints(self):
        for path in ('/stop', '/exec?cmd=id', '/containers/delete', '/settings',
                     '/run/secrets/ops-ui-password', '/backups/file.enc', '/backup'):
            self.assertEqual(self.request(auth=self.auth, path=path)[0], 404)
            if path != '/backup':
                self.assertEqual(self.post(path=path)[0], 404)
        self.assertEqual(self.request('DELETE', '/', self.auth)[0], 501)
        self.assertEqual(self.request('PUT', '/', self.auth)[0], 501)
        self.assertEqual(self.calls, [])
        self.assertEqual(self.request(path='/icon.svg')[0], 200)

    def test_success_backup_names_sizes_and_untrusted_files(self):
        folder = self.root / '20261003T000000Z-1234abcd'
        folder.mkdir()
        for name in ('manifest.json', 'database.enc', 'secrets.enc', 'configuration.enc'):
            (folder / name).write_bytes(b'x' * 5)
        manifest = {'version': 1, 'files': ['database.enc', 'secrets.enc', 'configuration.enc']}
        (folder / 'manifest.json').write_text(json.dumps(manifest))
        (self.root / 'last-success.json').write_text(json.dumps({'completed_at': '2026-10-03T00:00:00+00:00', 'backup': folder.name, 'secret': self.env_secret}))
        (self.root / 'untrusted-password-file').write_text(self.env_secret)
        body = self.request(auth=self.auth)[2]
        self.assertIn(folder.name.encode(), body)
        self.assertIn(f'{15 + (folder / "manifest.json").stat().st_size} bytes'.encode(), body)
        self.assertNotIn(b'untrusted-password-file', body)
        self.assertNotIn(self.env_secret.encode(), body)

    def test_missing_password_disables_listener_and_invalid_password_fails_closed(self):
        path = self.root / 'password'
        self.assertIsNone(web.load_password(path))
        path.write_bytes(self.password + b'\n')
        path.chmod(0o600)
        self.assertEqual(web.load_password(path), self.password)
        path.chmod(0o644)
        with self.assertRaises(ValueError):
            web.load_password(path)
        path.chmod(0o600)
        path.write_bytes(b'short')
        with self.assertRaises(ValueError):
            web.load_password(path)
        with patch.object(web, 'load_password', return_value=None), patch.object(web.subprocess, 'Popen') as child:
            web.start_background()
            child.assert_not_called()

    def test_web_runner_passes_original_lock_fd_to_backup(self):
        config = {'database_user': 'backup-role'}
        with (self.root / '.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with patch.object(ops.subprocess, 'run') as run:
                run.return_value.returncode = 0
                self.assertEqual(ops.run_backup(config, self.root, backup_lock=lock), 0)
            command = run.call_args.args[0]
            self.assertEqual(command[-2:], ['--lock-fd', str(lock.fileno())])
            self.assertEqual(run.call_args.kwargs['pass_fds'], (lock.fileno(),))

    def test_ui_health_rejects_dead_root_and_reused_pid(self):
        pid = self.root / 'ui.pid'
        pid.write_text('123')
        proc = self.root / '123'
        proc.mkdir()
        (proc / 'status').write_text('State:\tS\nUid:\t999\n')
        (proc / 'cmdline').write_bytes(b'python3\0' + os.fsencode(Path(ops.__file__).with_name('ops_web.py')) + b'\0')
        ops.check_ui_health(pid, self.root)
        for status in ('State:\tZ\nUid:\t999\n', 'State:\tS\nUid:\t0\n'):
            (proc / 'status').write_text(status)
            with self.assertRaises(ops.OpsError):
                ops.check_ui_health(pid, self.root)
        (proc / 'status').write_text('State:\tS\nUid:\t999\n')
        (proc / 'cmdline').write_bytes(b'python3\0other.py\0')
        with self.assertRaises(ops.OpsError):
            ops.check_ui_health(pid, self.root)

    def test_inherited_lock_survives_real_backup_child_with_fake_docker(self):
        key = self.root / 'key'
        key.write_bytes(bytes(range(32)))
        key.chmod(0o600)
        backups = self.root / 'daily'
        backups.mkdir()
        config = self.root / 'config.json'
        config.write_text(json.dumps({'key_file': str(key), 'backup_directory': str(backups),
                                      'postgres_container': 'fake-postgres', 'server_container': 'fake-server',
                                      'database_user': 'fake-role', 'database': 'fake-db',
                                      'server_instance_id': 'fake-instance'}))
        fake = self.root / 'docker'
        fake.write_text('#!/usr/bin/env python3\nimport sys\na=sys.argv[1:]\nif "psql" in a:\n print("fake-instance")\nelse:\n sys.stdout.buffer.write(b"synthetic encrypted backup input")\n')
        fake.chmod(0o700)
        environment = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ['PATH'])
        with (backups / '.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = subprocess.run([sys.executable, str(ROOT / 'Scripts/operations/backup.py'),
                                     '--config', str(config), '--lock-fd', str(lock.fileno())],
                                    pass_fds=(lock.fileno(),), capture_output=True, env=environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((backups / 'last-success.json').is_file())
            with (backups / '.lock').open('a') as competing:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(competing, fcntl.LOCK_EX | fcntl.LOCK_NB)


if __name__ == '__main__':
    unittest.main()
