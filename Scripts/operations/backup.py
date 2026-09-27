#!/usr/bin/env python3
"""Encrypted local PostgreSQL backups. No Cloudflare storage dependency."""
import argparse
import calendar
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

MAGIC = b'FUMIBK01'
UTC = dt.timezone.utc


def anniversary(value):
    year = value.year + 1
    return value.replace(year=year, day=min(value.day, calendar.monthrange(year, value.month)[1]))


def encrypt(source, destination, key):
    nonce = os.urandom(12)
    header = MAGIC + nonce
    worker = Cipher(algorithms.AES(key), modes.GCM(nonce)).encryptor()
    worker.authenticate_additional_data(header)
    with destination.open('xb') as out:
        os.chmod(destination, 0o600)
        out.write(header)
        while chunk := source.read(1024 * 1024):
            out.write(worker.update(chunk))
        out.write(worker.finalize())
        out.write(worker.tag)
        out.flush()
        os.fsync(out.fileno())


def decrypt(source, key, output=None):
    with source.open('rb') as stream:
        header = stream.read(20)
        if header[:8] != MAGIC:
            raise ValueError('invalid backup format')
        size = source.stat().st_size - 36
        if size < 0:
            raise ValueError('truncated backup')
        stream.seek(-16, 2)
        tag = stream.read(16)
        stream.seek(20)
        worker = Cipher(algorithms.AES(key), modes.GCM(header[8:], tag)).decryptor()
        worker.authenticate_additional_data(header)
        while size:
            chunk = stream.read(min(size, 1024 * 1024))
            if not chunk:
                raise ValueError('truncated backup')
            size -= len(chunk)
            plain = worker.update(chunk)
            if output:
                output.write(plain)
        worker.finalize()


def capture(command, target, key):
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as child:
        try:
            encrypt(child.stdout, target, key)
            error = child.stderr.read()
            if child.wait() != 0:
                raise RuntimeError('backup source command failed')
            decrypt(target, key)
        except BaseException:
            child.kill()
            child.wait()
            target.unlink(missing_ok=True)
            raise


def run(config):
    root = Path(config['backup_directory'])
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    key_path = Path(config['key_file'])
    if root.resolve() in key_path.resolve().parents:
        raise ValueError('backup key must be outside the backup directory')
    key = key_path.read_bytes()
    if len(key) != 32 or key_path.stat().st_mode & 0o077:
        raise ValueError('backup key must be 32 bytes and private')
    with (root / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        instance = subprocess.check_output([
            'docker', 'exec', config['postgres_container'], 'psql', '-XAt',
            '-U', config['database_user'], '-d', config['database'], '-c',
            'SELECT server_instance_id FROM sync_v2.deployment_binding WHERE singleton'
        ], stderr=subprocess.PIPE).decode().strip()
        if instance != config['server_instance_id']:
            raise ValueError('unexpected database identity')
        now = dt.datetime.now(UTC)
        folder = root / (now.strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8])
        folder.mkdir(mode=0o700)
        try:
            capture(['docker', 'exec', config['postgres_container'], 'pg_dump',
                     '-U', config['database_user'], '-d', config['database'], '-Fc'],
                    folder / 'database.enc', key)
            # Includes the vault/HMAC/Apple keys required to recover this DB.
            capture(['docker', 'exec', config['server_container'], 'tar', '-C',
                     '/run', '-cf', '-', 'secrets'], folder / 'secrets.enc', key)
            capture(['docker', 'inspect', config['server_container'], config['postgres_container']],
                    folder / 'configuration.enc', key)
            manifest = {'version': 1, 'created_at': now.isoformat(),
                        'expires_at': anniversary(now).isoformat(),
                        'server_instance_id': instance,
                        'files': ['database.enc', 'secrets.enc', 'configuration.enc']}
            path = folder / 'manifest.json'
            path.write_text(json.dumps(manifest, indent=2) + '\n')
            os.chmod(path, 0o600)
        except BaseException:
            # Partial output is not a backup and never triggers retention pruning.
            for name in ['database.enc', 'secrets.enc', 'configuration.enc', 'manifest.json']:
                (folder / name).unlink(missing_ok=True)
            folder.rmdir()
            raise
        # Only our complete manifests and exact known files may be pruned.
        for candidate in root.iterdir():
            if candidate.is_symlink() or not candidate.is_dir() or candidate == folder:
                continue
            try:
                record = json.loads((candidate / 'manifest.json').read_text())
                created = dt.datetime.fromisoformat(record['created_at'])
                if record['version'] != 1 or record['server_instance_id'] != instance:
                    continue
                files = record['files']
                if set(files) not in ({'database.enc', 'secrets.enc'}, {'database.enc', 'secrets.enc', 'configuration.enc'}):
                    continue
                if set(p.name for p in candidate.iterdir()) != set(files) | {'manifest.json'}:
                    continue
                if created.tzinfo is None or anniversary(created) > now:
                    continue
                if any(p.is_symlink() for p in candidate.iterdir()):
                    continue
                for name in files + ['manifest.json']:
                    (candidate / name).unlink()
                candidate.rmdir()
            except (ValueError, KeyError, OSError):
                continue
        status = root / 'last-success.json'
        temporary = root / '.last-success.tmp'
        temporary.write_text(json.dumps({'completed_at': dt.datetime.now(UTC).isoformat(),
                                         'backup': folder.name}) + '\n')
        os.chmod(temporary, 0o600)
        temporary.replace(status)
        print('Encrypted database and key backup completed')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config')
    parser.add_argument('--decrypt')
    parser.add_argument('--key-file')
    args = parser.parse_args()
    if args.decrypt:
        key = Path(args.key_file).read_bytes()
        # Authenticate the entire file before emitting any bytes to a restore tool.
        decrypt(Path(args.decrypt), key)
        decrypt(Path(args.decrypt), key, sys.stdout.buffer)
    else:
        run(json.loads(Path(args.config).read_text()))


if __name__ == '__main__':
    os.umask(0o077)
    main()
