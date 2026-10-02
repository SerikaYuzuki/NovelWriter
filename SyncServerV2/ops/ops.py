#!/usr/bin/env python3
"""Non-root daily backup runner. The backup format/retention lives in backup.py."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
from zoneinfo import ZoneInfo

UTC = dt.timezone.utc
OPS_UID, OPS_GID = 999, 1000
SOCKET = Path('/var/run/docker.sock')
STATE_DIRECTORY = Path('/run/ops')
CONFIG = Path('/run/secrets/backup-config.json')
BACKUP_DIRECTORY = Path('/backups')
KEY_FILE = Path('/run/secrets/backup-aes256.key')
MAX_SUCCESS_AGE = dt.timedelta(hours=36)


class OpsError(ValueError):
    """An operator-facing message that never includes private file contents."""


def schedule(environment):
    timezone = environment.get('TZ', 'Asia/Tokyo')
    zone = ZoneInfo(timezone)  # Fail startup for an unknown timezone.
    value = environment.get('BACKUP_TIME', '03:17')
    if not re.fullmatch(r'(?:[01][0-9]|2[0-3]):[0-5][0-9]', value):
        raise OpsError('BACKUP_TIME must be HH:MM')
    hour, minute = map(int, value.split(':'))
    return zone, hour, minute


def crontab(environment):
    zone, hour, minute = schedule(environment)
    return (f'CRON_TZ={zone.key}\n'
            f'{minute} {hour} * * * /usr/local/bin/run-backup\n')


def next_execution(environment, now):
    zone, hour, minute = schedule(environment)
    # Iterate UTC minutes so a configurable DST zone skips nonexistent times
    # and recognizes both occurrences of an ambiguous local time like cron.
    candidate = now.astimezone(UTC).replace(second=0, microsecond=0)
    for _ in range(3 * 24 * 60):
        candidate += dt.timedelta(minutes=1)
        local = candidate.astimezone(zone)
        if (local.hour, local.minute) == (hour, minute):
            return local
    raise OpsError('no daily execution within three days')


def become_ops(socket=SOCKET):
    metadata = socket.stat()
    if not stat.S_ISSOCK(metadata.st_mode):
        raise OpsError('Docker socket mount is not a socket')
    if os.getuid() == 0:
        # No changes to host socket permissions or image /etc/group required.
        os.setgroups(sorted({OPS_GID, metadata.st_gid}))
        os.setgid(OPS_GID)
        os.setuid(OPS_UID)
    if os.getuid() != OPS_UID or os.getgid() != OPS_GID:
        raise OpsError('ops requires uid 999 / gid 1000')
    if not os.access(socket, os.R_OK | os.W_OK):
        raise OpsError('ops cannot access Docker socket via its group')


def runtime_config(source, environment):
    config = dict(source)
    # Host config stays read-only and unchanged; all other keys are preserved,
    # including database_user (required by backup.py) and server_instance_id.
    config['backup_directory'] = str(BACKUP_DIRECTORY)
    config['key_file'] = str(KEY_FILE)
    for key in ('postgres_container', 'server_container'):
        if environment.get(key.upper()):
            config[key] = environment[key.upper()]
    for key in ('database', 'database_user', 'postgres_container',
                'server_container', 'server_instance_id'):
        if not isinstance(config.get(key), str) or not config[key]:
            raise OpsError(f'missing backup configuration field: {key}')
    return config


def load_config():
    return runtime_config(json.loads(CONFIG.read_text()), os.environ)


def run_backup(config, state_directory=STATE_DIRECTORY, backup_lock=None):
    # Unique temporary config per invocation: concurrent manual/cron runs
    # still compete on backup.py's original /backups/.lock, never a new lock.
    with tempfile.NamedTemporaryFile(mode='w', prefix='backup-', suffix='.json',
                                     dir=state_directory) as temporary:
        json.dump(config, temporary)
        temporary.flush()
        print('ops: backup started', flush=True)
        command = [
            'python3', str(Path(__file__).with_name('backup.py')),
            '--config', temporary.name,
        ]
        options = {}
        if backup_lock is not None:
            command += ['--lock-fd', str(backup_lock.fileno())]
            options['pass_fds'] = (backup_lock.fileno(),)
        result = subprocess.run(command, check=False, **options)
        print(f'ops: backup finished exit={result.returncode}', flush=True)
        return result.returncode


def check_health(status_path, now, proc_directory=Path('/proc/1')):
    # Supercronic replaces the entrypoint as PID 1; an unrelated live process
    # or a zombie is not a healthy cron daemon.
    if (proc_directory / 'comm').read_text().strip() != 'supercronic':
        raise OpsError('cron daemon is not running as PID 1')
    process_status = (proc_directory / 'status').read_text().splitlines()
    state = next(line.split()[1] for line in process_status if line.startswith('State:'))
    uid = next(line.split()[1] for line in process_status if line.startswith('Uid:'))
    if state not in ('S', 'R', 'D', 'I') or uid != str(OPS_UID):
        raise OpsError('cron daemon is not alive under uid 999')
    record = json.loads(status_path.read_text())
    completed = dt.datetime.fromisoformat(record['completed_at'])
    if completed.tzinfo is None:
        raise OpsError('backup success timestamp must include timezone')
    age = now.astimezone(UTC) - completed.astimezone(UTC)
    if age < dt.timedelta(0) or age >= MAX_SUCCESS_AGE:
        raise OpsError('backup success is outside the 36-hour window')


def check_ui_health(pid_path, proc_root=Path('/proc')):
    proc = proc_root / str(int(pid_path.read_text()))
    status = (proc / 'status').read_text().splitlines()
    state = next(line.split()[1] for line in status if line.startswith('State:'))
    uid = next(line.split()[1] for line in status if line.startswith('Uid:'))
    command = (proc / 'cmdline').read_bytes().split(b'\0')
    if (state not in ('S', 'R', 'D', 'I') or uid != str(OPS_UID)
            or os.fsencode(Path(__file__).with_name('ops_web.py')) not in command):
        raise OpsError('ops UI process is not alive under uid 999')


def start():
    config = load_config()
    if not os.access(BACKUP_DIRECTORY, os.R_OK | os.W_OK | os.X_OK):
        raise OpsError('backup directory must be writable by uid 999')
    key = KEY_FILE.stat()
    if key.st_size != 32 or key.st_mode & 0o077 or not os.access(KEY_FILE, os.R_OK):
        raise OpsError('backup key must be readable, 32 bytes and private')
    # Read config now to fail early, but every job reloads it from the mount.
    del config
    cron_path = STATE_DIRECTORY / 'crontab'
    cron_path.write_text(crontab(os.environ))
    cron_path.chmod(0o600)
    upcoming = next_execution(os.environ, dt.datetime.now(UTC))
    print(f'ops: next backup={upcoming.isoformat()} TZ={upcoming.tzinfo.key}', flush=True)
    # Also supports source-file import in the host unit tests.
    sys.path.insert(0, str(Path(__file__).parent))
    import ops_web
    ops_web.start_background()
    os.execvp('supercronic', ['supercronic', str(cron_path)])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=('start', 'backup', 'health'))
    args = parser.parse_args()
    os.umask(0o077)
    try:
        become_ops()
        if args.command == 'start':
            start()  # No backup on startup and no missed-run catch-up.
        elif args.command == 'backup':
            return run_backup(load_config())
        else:
            check_health(BACKUP_DIRECTORY / 'last-success.json', dt.datetime.now(UTC))
            ui_pid = STATE_DIRECTORY / 'ops-ui.pid'
            if ui_pid.exists():
                check_ui_health(ui_pid)
            elif Path('/run/secrets/ops-ui-password').exists():
                raise OpsError('configured ops UI failed to start')
    except OpsError as error:
        print(f'ops: {args.command} failed: {error}', flush=True)
        return 1
    except Exception as error:
        # Configuration contents, credentials and exception payloads stay private.
        print(f'ops: {args.command} failed ({type(error).__name__})', flush=True)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
