#!/usr/bin/env python3
import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("recovery", Path(__file__).with_name("export-local-recovery.py"))
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)
FIXTURES = Path(__file__).resolve().parents[1] / "docs/sync/v2/fixtures/canonical"

class LocalRecoveryTests(unittest.TestCase):
    def test_recovers_full_fixture_and_preserves_source(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            source = root / "source.sqlite"
            with sqlite3.connect(source) as db:
                db.executescript("CREATE TABLE works(work_id TEXT,current_snapshot_id BLOB); CREATE TABLE snapshots(snapshot_id BLOB,work_id TEXT,manifest_bytes BLOB); CREATE TABLE objects(object_id BLOB,bytes BLOB); CREATE TABLE work_resources(work_id TEXT,path_components TEXT,kind TEXT,object_id BLOB); CREATE TABLE resources(object_id BLOB,bytes BLOB);")
                raw = (FIXTURES / "snapshot.json").read_bytes()
                manifest = json.loads(raw)
                digest = hashlib.sha256(raw).digest()
                db.execute("INSERT INTO works VALUES(?,?)", (manifest["workId"],digest))
                db.execute("INSERT INTO snapshots VALUES(?,?,?)", (digest,manifest["workId"],raw))
                for obj in json.loads((FIXTURES / "object-hashes.json").read_text())["objects"]:
                    db.execute("INSERT INTO objects VALUES(?,?)",(bytes.fromhex(obj["objectId"]),(FIXTURES / "objects" / obj["file"]).read_bytes()))
            before = source.read_bytes()
            self.assertEqual(recovery.export_database(source, root / "recovered"), 1)
            output = root / "recovered" / manifest["workId"]
            self.assertTrue((output / "本文.md").read_text())
            self.assertTrue((output / "資料.md").read_text())
            self.assertEqual((output / "添付/00000000-0000-4000-8000-000000000107/map.txt").read_bytes(), (FIXTURES / "objects/attachment-bytes.txt").read_bytes())
            self.assertEqual(source.read_bytes(), before)
            with self.assertRaises(FileExistsError):
                recovery.export_database(source, root / "recovered")
    def test_recovers_ai_history_without_changing_original(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            source = root / "writing-assistant.sqlite"
            output = root / "export"; output.mkdir()
            with sqlite3.connect(source) as db:
                db.executescript("CREATE TABLE records(namespace TEXT,bytes TEXT,sequence INTEGER,conflicted INTEGER,local_order INTEGER); CREATE TABLE edits(namespace TEXT,id TEXT,payload TEXT,state TEXT);")
                record = {"id":"example", "kind":"message", "key":"chat", "createdAt":"2026-09-26T00:00:00Z", "payload":json.dumps({"text":"原稿についての会話"})}
                db.execute("INSERT INTO records VALUES(?,?,1,0,1)",("work:test",json.dumps(record)))
                db.execute("INSERT INTO edits VALUES('work:test','request','{}','prepared')")
            before = source.read_bytes()
            recovery.export_assistant(source, output)
            self.assertIn("原稿についての会話",(output / "AI会話とプロンプト.md").read_text())
            self.assertEqual(json.loads((output / "AI変更履歴.json").read_text())[0]["state"],"prepared")
            self.assertEqual(source.read_bytes(),before)

    def test_rejects_escaping_paths(self):
        for path in [["..", "secret"], ["/tmp/secret"], ["a\\b"]]:
            with self.assertRaises(ValueError):
                recovery.safe_path(Path("/tmp/recovery"),path)

if __name__ == "__main__":
    unittest.main()
