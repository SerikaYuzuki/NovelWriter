import datetime as dt
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from zoneinfo import ZoneInfoNotFoundError

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ops', ROOT / 'SyncServerV2/ops/ops.py')
ops = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ops)
backup_spec = importlib.util.spec_from_file_location('backup', Path(__file__).with_name('backup.py'))
backup = importlib.util.module_from_spec(backup_spec)
backup_spec.loader.exec_module(backup)


class ScheduleTests(unittest.TestCase):
    def test_default_cron_and_next_japan_time(self):
        self.assertEqual(ops.crontab({}),
                         'CRON_TZ=Asia/Tokyo\n17 3 * * * /usr/local/bin/run-backup\n')
        before = dt.datetime(2026, 10, 2, 18, 16, 59, tzinfo=ops.UTC)
        self.assertEqual(ops.next_execution({}, before).isoformat(), '2026-10-03T03:17:00+09:00')
        at = before + dt.timedelta(seconds=1)
        self.assertEqual(ops.next_execution({}, at).isoformat(), '2026-10-04T03:17:00+09:00')

    def test_custom_time_and_timezone(self):
        environment = {'TZ': 'Europe/London', 'BACKUP_TIME': '00:05'}
        self.assertEqual(ops.crontab(environment),
                         'CRON_TZ=Europe/London\n5 0 * * * /usr/local/bin/run-backup\n')
        now = dt.datetime(2026, 10, 2, 23, 30, tzinfo=ops.UTC)
        self.assertEqual(ops.next_execution(environment, now).isoformat(), '2026-10-04T00:05:00+01:00')

    def test_invalid_schedule_is_rejected(self):
        for value in ('3:17', '24:00', '03:60', '* * * * *', '03:17\necho surprise', ''):
            with self.subTest(value=value), self.assertRaises(ValueError):
                ops.crontab({'BACKUP_TIME': value})
        with self.assertRaises(ZoneInfoNotFoundError):
            ops.crontab({'TZ': 'No/SuchZone'})

    def test_dst_gap_and_repeated_minute(self):
        environment = {'TZ': 'Europe/London', 'BACKUP_TIME': '01:17'}
        now = dt.datetime(2026, 3, 29, 0, 59, tzinfo=ops.UTC)
        self.assertEqual(ops.next_execution(environment, now).isoformat(), '2026-03-30T01:17:00+01:00')
        now = dt.datetime(2026, 10, 25, 0, 18, tzinfo=ops.UTC)
        self.assertEqual(ops.next_execution(environment, now).isoformat(), '2026-10-25T01:17:00+00:00')


class HealthTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.proc = self.root / 'proc'
        self.proc.mkdir()
        (self.proc / 'comm').write_text('supercronic\n')
        (self.proc / 'status').write_text('State:\tS (sleeping)\nUid:\t999\t999\t999\t999\n')
        self.status = self.root / 'last-success.json'
        self.now = dt.datetime(2026, 10, 3, 0, 0, tzinfo=ops.UTC)

    def completed(self, value):
        self.status.write_text(json.dumps({'completed_at': value}))

    def test_36_hour_boundary_uses_timestamp_not_mtime(self):
        for age in (dt.timedelta(hours=35, minutes=59, seconds=59), dt.timedelta(hours=36),
                    dt.timedelta(hours=36, seconds=1)):
            self.completed((self.now - age).isoformat())
            os.utime(self.status, (0, 0))
            if age < ops.MAX_SUCCESS_AGE:
                ops.check_health(self.status, self.now, self.proc)
            else:
                with self.assertRaises(ValueError):
                    ops.check_health(self.status, self.now, self.proc)

    def test_timezone_offset_is_respected(self):
        self.completed('2026-10-02T21:00:00+09:00')
        ops.check_health(self.status, self.now, self.proc)

    def test_absent_malformed_naive_and_future_success_fail(self):
        with self.assertRaises(FileNotFoundError):
            ops.check_health(self.status, self.now, self.proc)
        for value in ('bad', '2026-10-03T00:00:00', '2026-10-03T00:00:01+00:00'):
            self.completed(value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                ops.check_health(self.status, self.now, self.proc)
        self.status.write_text('broken json')
        with self.assertRaises(ValueError):
            ops.check_health(self.status, self.now, self.proc)

    def test_daemon_must_be_alive_and_nonroot(self):
        self.completed(self.now.isoformat())
        (self.proc / 'comm').write_text('python3\n')
        with self.assertRaises(ValueError):
            ops.check_health(self.status, self.now, self.proc)
        (self.proc / 'comm').write_text('supercronic\n')
        for status in ('State:\tZ (zombie)\nUid:\t999\n',
                       'State:\tT (stopped)\nUid:\t999\n', 'State:\tS\nUid:\t0\n'):
            (self.proc / 'status').write_text(status)
            with self.assertRaises(ValueError):
                ops.check_health(self.status, self.now, self.proc)


class RunnerTests(unittest.TestCase):
    def config(self):
        return {'backup_directory': '/host/daily', 'key_file': '/host/key',
                'database': 'test', 'database_user': 'backup-role',
                'postgres_container': 'old-postgres', 'server_container': 'old-server',
                'server_instance_id': 'test-instance'}

    def test_host_config_is_preserved_except_mounts_and_explicit_names(self):
        source = self.config()
        config = ops.runtime_config(source, {'POSTGRES_CONTAINER': 'custom-postgres',
                                             'SERVER_CONTAINER': 'custom-server'})
        self.assertEqual(source, self.config())
        self.assertEqual(config['backup_directory'], '/backups')
        self.assertEqual(config['key_file'], '/run/secrets/backup-aes256.key')
        self.assertEqual(config['postgres_container'], 'custom-postgres')
        self.assertEqual(config['server_container'], 'custom-server')
        self.assertEqual(config['server_instance_id'], source['server_instance_id'])
        self.assertEqual(config['database_user'], 'backup-role')
        source.pop('database_user')
        with self.assertRaises(ValueError):
            ops.runtime_config(source, {})

    def test_manual_run_calls_bundled_backup_with_private_unique_config_and_exit_code(self):
        config = ops.runtime_config(self.config(), {})
        def invoke(command, check):
            self.assertEqual(Path(command[1]), ROOT / 'SyncServerV2/ops/backup.py')
            temporary = Path(command[3])
            self.assertEqual(json.loads(temporary.read_text()), config)
            self.assertEqual(stat.S_IMODE(temporary.stat().st_mode), 0o600)
            self.assertFalse(check)
            return SimpleNamespace(returncode=7)
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(ops.subprocess, 'run', side_effect=invoke):
                self.assertEqual(ops.run_backup(config, Path(directory)), 7)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_start_only_installs_schedule_without_running_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            with patch.object(ops, 'STATE_DIRECTORY', state), \
                 patch.object(ops, 'load_config', return_value=self.config()), \
                 patch.object(ops.os, 'access', return_value=True), \
                 patch.object(Path, 'stat', return_value=SimpleNamespace(st_size=32, st_mode=0o100600)), \
                 patch.dict(ops.os.environ, {'TZ': 'Asia/Tokyo', 'BACKUP_TIME': '03:17'}), \
                 patch.object(ops.os, 'execvp') as execute, \
                 patch.object(ops, 'run_backup') as run:
                ops.start()
            self.assertEqual((state / 'crontab').read_text(), ops.crontab({}))
            self.assertEqual(stat.S_IMODE((state / 'crontab').stat().st_mode), 0o600)
            execute.assert_called_once_with('supercronic', ['supercronic', str(state / 'crontab')])
            run.assert_not_called()

    def test_socket_group_is_set_before_permanent_privilege_drop(self):
        socket = SimpleNamespace(stat=lambda: SimpleNamespace(st_mode=stat.S_IFSOCK | 0o660, st_gid=1234))
        with patch.object(ops.os, 'getuid', side_effect=[0, 999]), \
             patch.object(ops.os, 'getgid', return_value=1000), \
             patch.object(ops.os, 'access', return_value=True), \
             patch.object(ops.os, 'setgroups') as groups, \
             patch.object(ops.os, 'setgid') as gid, \
             patch.object(ops.os, 'setuid') as uid:
            ops.become_ops(socket)
        groups.assert_called_once_with([1000, 1234])
        gid.assert_called_once_with(1000)
        uid.assert_called_once_with(999)

    def test_existing_backup_lock_prevents_a_second_source_command(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'backups'
            root.mkdir()
            key = Path(directory) / 'key'
            key.write_bytes(bytes(range(32)))
            key.chmod(0o600)
            config = self.config() | {'backup_directory': str(root), 'key_file': str(key)}
            with (root / '.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with patch.object(backup.subprocess, 'check_output') as source:
                    with self.assertRaises(BlockingIOError):
                        backup.run(config)
                    source.assert_not_called()
            self.assertEqual([p.name for p in root.iterdir()], ['.lock'])


if __name__ == '__main__':
    unittest.main()
