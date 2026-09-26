#!/usr/bin/env python3
"""Recover readable copies from a local v2 database, without starting FUMINIWA.

The source is opened read-only. sqlite backup() captures a consistent working
copy including WAL. No server, credential, migration or source deletion is used.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import uuid


def safe_path(root: Path, components: list[str]) -> Path:
    if not components or any(not c or c in (".", "..") or any(x in c for x in ("/", "\\", "\0")) for c in components):
        raise ValueError("unsafe resource path")
    return root.joinpath(*components)


def checked(data: bytes, digest: bytes) -> bytes:
    if hashlib.sha256(data).digest() != digest:
        raise ValueError("digest mismatch; original database was not changed")
    return data


def export_database(source: Path, destination: Path) -> int:
    # Requiring a fresh private directory prevents overwrites and symlink traversal.
    destination.mkdir(mode=0o700, parents=False, exist_ok=False)
    count = 0
    with tempfile.TemporaryDirectory(prefix="fuminiwa-recovery-") as temporary:
        with sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True) as original, sqlite3.connect(Path(temporary) / "copy.sqlite") as db:
            original.backup(db)
            for work_id, snapshot_id in db.execute("SELECT work_id,current_snapshot_id FROM works WHERE current_snapshot_id IS NOT NULL ORDER BY work_id"):
                uuid.UUID(work_id)
                row = db.execute("SELECT manifest_bytes FROM snapshots WHERE snapshot_id=? AND work_id=?", (snapshot_id, work_id)).fetchone()
                if row is None:
                    raise ValueError("missing snapshot")
                manifest_bytes = checked(row[0], snapshot_id)
                manifest = json.loads(manifest_bytes)
                if manifest["workId"] != work_id:
                    raise ValueError("work identity mismatch")
                entities, binaries = {}, {}
                for entry in manifest["entries"]:
                    digest = bytes.fromhex(entry["objectId"])
                    row = db.execute("SELECT bytes FROM objects WHERE object_id=?", (digest,)).fetchone()
                    if row is None:
                        raise ValueError("missing object")
                    data = checked(row[0], digest)
                    if len(data) != entry["byteCount"]:
                        raise ValueError("object size mismatch")
                    if entry["contentType"] == "application/octet-stream":
                        binaries[entry["entityKey"]] = data
                    else:
                        entities[entry["entityKey"]] = json.loads(data)
                folder = destination / work_id
                folder.mkdir(mode=0o700)
                manuscript = ["# " + entities["work/title"]["value"]]
                notes = []
                for chapter in entities["work/chapter-order"]["ids"]:
                    title = entities[f"chapter/{chapter}/title"]["value"]
                    manuscript.append("## " + title)
                    for episode in entities[f"chapter/{chapter}/episode-order"]["ids"]:
                        name = entities[f"episode/{episode}/title"]["value"]
                        manuscript.extend(["### " + name, entities[f"episode/{episode}/body"]["value"]])
                        notes.append("## " + title + " / " + name + "\n\n" + entities[f"episode/{episode}/memo"]["value"])
                for key, value in entities.items():
                    if key.startswith(("character/", "plot-card/", "flag/", "world-note/")) or key == "work/synopsis":
                        notes.append("## " + key + "\n\n" + json.dumps(value, ensure_ascii=False, indent=2))
                (folder / "本文.md").write_text("\n\n".join(manuscript), encoding="utf-8")
                (folder / "資料.md").write_text("\n\n".join(notes), encoding="utf-8")
                (folder / "entities.json").write_text(json.dumps(entities, ensure_ascii=False, indent=2), encoding="utf-8")
                (folder / "snapshot.json").write_bytes(manifest_bytes)
                for key, data in binaries.items():
                    parts = key.split("/")
                    if len(parts) != 3 or parts[0] != "attachment" or parts[2] != "bytes":
                        raise ValueError("unknown binary entity")
                    metadata = entities[f"attachment/{parts[1]}/metadata"]
                    path = safe_path(folder, ["添付", parts[1], metadata["fileName"]])
                    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                    path.write_bytes(data)
                for path_json, kind, digest in db.execute("SELECT path_components,kind,object_id FROM work_resources WHERE work_id=?", (work_id,)):
                    path = safe_path(folder, ["資料ファイル"] + json.loads(path_json))
                    if kind == "directory":
                        path.mkdir(mode=0o700, parents=True, exist_ok=True)
                    else:
                        row = db.execute("SELECT bytes FROM resources WHERE object_id=?", (digest,)).fetchone()
                        if row is None:
                            raise ValueError("missing resource")
                        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                        path.write_bytes(checked(row[0], digest))
                count += 1
    (destination / "復旧結果.txt").write_text(f"{count}作品を救出しました。元データは変更していません。\n", encoding="utf-8")
    return count


if __name__ == "__main__":
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", type=Path, help="snapshot-sync-v2.sqlite")
    parser.add_argument("destination", type=Path, help="new output folder (must not exist)")
    args = parser.parse_args()
    print(f"Recovered {export_database(args.database, args.destination)} works.")
