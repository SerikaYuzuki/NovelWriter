import datetime as dt
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import json
from cryptography.exceptions import InvalidTag

spec = importlib.util.spec_from_file_location('backup', Path(__file__).with_name('backup.py'))
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)

class BackupTests(unittest.TestCase):
    def test_calendar_year_and_leap_day(self):
        self.assertEqual(backup.anniversary(dt.datetime(2024,2,29,tzinfo=backup.UTC)), dt.datetime(2025,2,28,tzinfo=backup.UTC))
        self.assertEqual(backup.anniversary(dt.datetime(2023,3,1,tzinfo=backup.UTC)), dt.datetime(2024,3,1,tzinfo=backup.UTC))

    def test_round_trip_and_authentication(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'database.enc'
            data = b'synthetic database\x00' * 100000
            key = bytes(range(32))
            backup.encrypt(io.BytesIO(data), path, key)
            backup.decrypt(path,key)
            output=io.BytesIO(); backup.decrypt(path,key,output)
            self.assertEqual(data,output.getvalue())
            self.assertNotIn(b'synthetic database',path.read_bytes())
            with self.assertRaises(InvalidTag): backup.decrypt(path,bytes(32))
            content=bytearray(path.read_bytes()); content[100]^=1; path.write_bytes(content)
            with self.assertRaises(InvalidTag): backup.decrypt(path,key)

    def test_retention_only_after_success_and_only_managed_files(self):
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory); root=base/'backups'; root.mkdir()
            key=base/'key'; key.write_bytes(bytes(range(32))); key.chmod(0o600)
            config={'backup_directory':str(root),'key_file':str(key),'postgres_container':'test','server_container':'test', 'database_user':'test','database':'test','server_instance_id':'test-instance'}
            old=dt.datetime(dt.datetime.now(backup.UTC).year-2,1,1,tzinfo=backup.UTC)
            def record(name,created,extra=False):
                folder=root/name; folder.mkdir()
                for file in ['database.enc','secrets.enc']: (folder/file).write_bytes(b'fixture')
                (folder/'manifest.json').write_text(json.dumps({'version':1,'created_at':created.isoformat(),'server_instance_id':'test-instance','files':['database.enc','secrets.enc']}))
                if extra: (folder/'unmanaged').write_text('retain')
                return folder
            expired=record('expired',old); unknown=record('unknown',old,True)
            recent=record('recent',dt.datetime.now(backup.UTC))
            with patch.object(backup.subprocess,'check_output',return_value=b'test-instance'), patch.object(backup,'capture',side_effect=RuntimeError('synthetic failure')):
                with self.assertRaises(RuntimeError): backup.run(config)
            self.assertTrue(expired.exists())
            def fake_capture(command,target,key): backup.encrypt(io.BytesIO(b'fixture'),target,key)
            with patch.object(backup.subprocess,'check_output',return_value=b'test-instance'), patch.object(backup,'capture',side_effect=fake_capture): backup.run(config)
            self.assertFalse(expired.exists()); self.assertTrue(unknown.exists()); self.assertTrue(recent.exists())
            self.assertTrue((root/'last-success.json').exists())

if __name__=='__main__': unittest.main()
