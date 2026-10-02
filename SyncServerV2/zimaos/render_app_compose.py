#!/usr/bin/env python3
"""Inspect old containers, preserve runtime settings, validate a concrete Compose.

The template is JSON; output is block YAML with quoted strings, stdlib only.
No secret contents, .env, source compose or CasaOS app files are read.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
BASE = '/DATA/AppData/fuminiwa-sync-v2-role-split'
NAMES = {'postgres': 'fuminiwa-sync-v2-role-split-postgres',
         'server': 'fuminiwa-sync-v2-role-split-server',
         'edge': 'fuminiwa-sync-v2-role-split-edge', 'ops': 'fuminiwa-sync-v2-ops'}
SERVER_SECRETS = ('runtime-password', 'auth-vault-key', 'auth-vault-keyring',
                  'auth-subject-hmac-key', 'auth-token-hmac-key',
                  'apple-sign-in-key.p8', 'google-client-secret')
REQUIRED_ENV = ('FUMINIWA_RUNTIME_MODE', 'FUMINIWA_SERVER_INSTANCE_ID',
                'FUMINIWA_SYNC_V2_BIND', 'FUMINIWA_SYNC_V2_POSTGRES_HOST',
                'FUMINIWA_SYNC_V2_POSTGRES_PORT', 'FUMINIWA_SYNC_V2_POSTGRES_DB',
                'FUMINIWA_SYNC_V2_POSTGRES_USER', 'FUMINIWA_SYNC_V2_POSTGRES_PASSWORD_FILE',
                'FUMINIWA_AUTH_VAULT_KEY_VERSION', 'FUMINIWA_AUTH_VAULT_KEY_FILE',
                'FUMINIWA_AUTH_VAULT_KEYRING_FILE', 'FUMINIWA_AUTH_SUBJECT_HMAC_KEY_FILE',
                'FUMINIWA_AUTH_TOKEN_HMAC_KEY_FILE', 'FUMINIWA_APPLE_TEAM_ID',
                'FUMINIWA_APPLE_KEY_ID', 'FUMINIWA_APPLE_MAC_CLIENT_ID',
                'FUMINIWA_APPLE_IOS_CLIENT_ID', 'FUMINIWA_APPLE_WEB_CLIENT_ID',
                'FUMINIWA_APPLE_PRIVATE_KEY_FILE', 'FUMINIWA_GOOGLE_CLIENT_SECRET_FILE')
FILE_ENV = {'runtime-password': 'FUMINIWA_SYNC_V2_POSTGRES_PASSWORD_FILE',
            'auth-vault-key': 'FUMINIWA_AUTH_VAULT_KEY_FILE',
            'auth-vault-keyring': 'FUMINIWA_AUTH_VAULT_KEYRING_FILE',
            'auth-subject-hmac-key': 'FUMINIWA_AUTH_SUBJECT_HMAC_KEY_FILE',
            'auth-token-hmac-key': 'FUMINIWA_AUTH_TOKEN_HMAC_KEY_FILE',
            'apple-sign-in-key.p8': 'FUMINIWA_APPLE_PRIVATE_KEY_FILE',
            'google-client-secret': 'FUMINIWA_GOOGLE_CLIENT_SECRET_FILE'}
EXTERNAL_MOUNTS = {
    'postgres': {'/var/lib/postgresql/data': 'fuminiwa-sync-v2-role-split-data'},
    'edge': {'/data': 'fuminiwa-sync-v2-role-split-caddy-data',
             '/config': 'fuminiwa-sync-v2-role-split-caddy-config'},
}


class RenderError(ValueError):
    pass


def docker(*args):
    result = subprocess.run(['docker', *args], capture_output=True, timeout=60, check=False)
    if result.returncode:
        raise RenderError('Docker command failed (details withheld)')
    try:
        return json.loads(result.stdout)
    except ValueError:
        raise RenderError('invalid Docker JSON') from None


def need(value, field):
    if value is None or value == '' or value == []:
        raise RenderError('missing ' + field)
    return value


def environment(item):
    result = {}
    for pair in need(item['Config'].get('Env'), 'environment'):
        key, sep, value = pair.partition('=')
        if not sep or key in result or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', key):
            raise RenderError('invalid environment entry')
        # Existing file references are retained. Inline credentials fail closed.
        if re.search(r'(?i)(password|secret|token|private_key|hmac_key|vault_key)', key) and not key.endswith(('_FILE', '_HOST_PATH', '_VERSION')) and value:
            raise RenderError('inline credential environment is unsupported')
        if re.search(r'(?i)(://[^/\s]+:[^/\s]+@|-----BEGIN .*PRIVATE KEY)', value):
            raise RenderError('inline credential value is unsupported')
        result[key] = value
    return result


def mount(item, target, kind):
    matches = [m for m in item['Mounts'] if m['Destination'] == target and m['Type'] == kind]
    if len(matches) != 1:
        raise RenderError('missing or ambiguous mount ' + target)
    return matches[0]


def host_path(value):
    if not isinstance(value, str) or not value.startswith('/') or '\n' in value or '\r' in value:
        raise RenderError('invalid absolute host path')
    return value


def bind(source, target, read_only=True):
    return {'type': 'bind', 'source': host_path(source), 'target': target,
            'read_only': read_only, 'bind': {'create_host_path': False}}


def literal(value):
    # Compose must not expand $FOO or ${...} from inspected concrete values.
    if isinstance(value, str):
        return value.replace('$', '$$')
    if isinstance(value, list):
        return [literal(v) for v in value]
    if isinstance(value, dict):
        return {k: literal(v) for k, v in value.items()}
    return value


def duration(nanoseconds):
    if type(nanoseconds) is not int or nanoseconds <= 0:
        raise RenderError('invalid healthcheck duration')
    for unit, scale in (('h', 3600 * 10**9), ('m', 60 * 10**9)):
        if nanoseconds % scale == 0:
            return str(nanoseconds // scale) + unit
    for unit, digits in (('s', 9), ('ms', 6), ('us', 3)):
        scale = 10**digits
        if nanoseconds >= scale or unit == 'us':
            whole, fraction = divmod(nanoseconds, scale)
            suffix = ('.' + f'{fraction:0{digits}d}'.rstrip('0')) if fraction else ''
            return str(whole) + suffix + unit


def yaml_quote(value):
    # JSON escapes are valid in YAML double quotes. Keep Unicode characters
    # (including non-BMP characters) intact, but escape YAML 1.1 line breaks
    # and non-printable characters so no scalar can create another YAML node.
    if any(0xD800 <= ord(char) <= 0xDFFF for char in value):
        raise RenderError('invalid Unicode scalar')
    quoted = json.dumps(value, ensure_ascii=False)
    return re.sub(r'[\x7f-\x9f\u2028\u2029\ufffe\uffff]',
                  lambda match: f'\\u{ord(match[0]):04x}', quoted)


def dump_yaml(document):
    """Small block-YAML emitter for JSON-shaped Compose data; no implicit strings."""
    lines = []

    def scalar(value):
        if isinstance(value, str):
            return yaml_quote(value)
        if value is None:
            return 'null'
        if type(value) is bool:
            return 'true' if value else 'false'
        if type(value) is int:
            return str(value)
        if value == {} and isinstance(value, dict):
            return '{}'
        if value == [] and isinstance(value, list):
            return '[]'
        raise RenderError('unsupported YAML value type')

    def emit(value, indent=0):
        prefix = ' ' * indent
        if isinstance(value, dict) and value:
            for key, child in value.items():
                if not isinstance(key, str):
                    raise RenderError('YAML keys must be strings')
                head = prefix + yaml_quote(key) + ':'
                if isinstance(child, (dict, list)) and child:
                    lines.append(head)
                    emit(child, indent + 2)
                else:
                    lines.append(head + ' ' + scalar(child))
        elif isinstance(value, list) and value:
            for child in value:
                if isinstance(child, (dict, list)) and child:
                    lines.append(prefix + '-')
                    emit(child, indent + 2)
                else:
                    lines.append(prefix + '- ' + scalar(child))
        else:
            lines.append(prefix + scalar(value))

    emit(document)
    return '\n'.join(lines) + '\n'


def check_volume_contract(document):
    """Fail closed before publishing if a template regresses CasaOS mounts."""
    names = {name for mounts in EXTERNAL_MOUNTS.values() for name in mounts.values()}
    volumes = document.get('volumes', {})
    if not isinstance(volumes, dict) or set(volumes) != names or any(
                                    not isinstance(volumes[name], dict)
                                    or set(volumes[name]) != {'name', 'external'}
                                    or volumes[name]['name'] != name
                                    or volumes[name]['external'] is not True for name in names):
        raise RenderError('external volume keys/names differ from expected names')
    if not set(EXTERNAL_MOUNTS).issubset(document['services']):
        raise RenderError('missing external volume service')
    for role, service in document['services'].items():
        expected = EXTERNAL_MOUNTS.get(role, {})
        found = {}
        for entry in service.get('volumes', []):
            if isinstance(entry, dict):
                if entry.get('type') != 'bind':
                    raise RenderError('named volumes must use short syntax')
                if entry.get('target') in expected:
                    raise RenderError('expected named volume replaced by bind')
                continue
            if not isinstance(entry, str):
                raise RenderError('invalid volume entry')
            parts = entry.split(':')
            if (len(parts) not in (2, 3) or (len(parts) == 3 and parts[2] != 'ro')
                    or parts[0] not in names or expected.get(parts[1]) != parts[0]
                    or parts[1] in found):
                raise RenderError('unexpected short volume reference')
            found[parts[1]] = parts[0]
        if found != expected:
            raise RenderError('missing expected external volume mount')


def settings(item, role):
    config, host = item['Config'], item['HostConfig']
    if host.get('Privileged') or host.get('NetworkMode') == 'host':
        raise RenderError('unexpected privileged runtime')
    for forbidden in ('Devices', 'DeviceRequests', 'Binds'):
        # Binds are represented and checked through Mounts below.
        if forbidden != 'Binds' and host.get(forbidden):
            raise RenderError('unsupported host device')
    if role != 'postgres' and host.get('ReadonlyRootfs') is not True:
        raise RenderError('read-only rootfs required')
    caps = need(host.get('CapDrop'), 'cap_drop')
    if 'ALL' not in caps or not any(v in ('no-new-privileges', 'no-new-privileges:true') for v in host.get('SecurityOpt', [])):
        raise RenderError('missing security settings')
    health = need(config.get('Healthcheck'), 'healthcheck')
    test = need(health.get('Test'), 'healthcheck test')
    if test == ['NONE']:
        raise RenderError('disabled healthcheck')
    result = {'environment': environment(item), 'read_only': host['ReadonlyRootfs'],
              'cap_drop': caps, 'security_opt': host['SecurityOpt'],
              'healthcheck': {'test': test}}
    if host.get('CapAdd'):
        result['cap_add'] = host['CapAdd']
    for source, target in (('Interval', 'interval'), ('Timeout', 'timeout'),
                           ('StartPeriod', 'start_period'), ('StartInterval', 'start_interval')):
        if health.get(source):
            result['healthcheck'][target] = duration(health[source])
    if health.get('Retries'):
        result['healthcheck']['retries'] = health['Retries']
    if host.get('Tmpfs'):
        result['tmpfs'] = [target + ':' + options for target, options in host['Tmpfs'].items()]
    for source, target in (('User', 'user'), ('WorkingDir', 'working_dir'),
                           ('Entrypoint', 'entrypoint'), ('Cmd', 'command'), ('StopSignal', 'stop_signal')):
        if config.get(source):
            result[target] = config[source]
    log = host.get('LogConfig')
    if log and log.get('Type'):
        result['logging'] = {'driver': log['Type'], 'options': log.get('Config', {})}
    return result


def digest(image, repository):
    choices = [ref for ref in image.get('RepoDigests', [])
               if re.fullmatch(r'(?:.+/)?' + repository + r'@sha256:[0-9a-f]{64}', ref)]
    if not choices:
        raise RenderError('missing ' + repository + ' RepoDigest')
    return sorted(choices)[0]


def registry_ref(ref, repository):
    if not re.fullmatch(r'127\.0\.0\.1:5000/' + repository + r':[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}', ref):
        raise RenderError('invalid local registry reference')
    return ref


def render(items, images, server_image, ops_image, ui_password, caddyfile, ui_host, ui_port):
    template = json.loads((HERE / 'app-compose.template.yml').read_text())
    services = template['services']
    for role, item in items.items():
        if item.get('Name') != '/' + NAMES[role] or not item.get('State', {}).get('Running'):
            raise RenderError('source container must be running: ' + role)
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', item.get('Image', '')):
            raise RenderError('missing source image ID: ' + role)
        services[role].update(literal(settings(item, role)))
    server_image = registry_ref(server_image, 'fuminiwa-sync-v2-server')
    ops_image = registry_ref(ops_image, 'fuminiwa-sync-v2-ops')
    if images[server_image]['Id'] != items['server']['Image']:
        raise RenderError('server registry tag differs from running image')
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', images[ops_image].get('Id', '')):
        raise RenderError('missing ops image ID')
    for role, repo in (('postgres', 'postgres'), ('edge', 'caddy')):
        services[role]['image'] = digest(images[items[role]['Image']], repo)
    services['server']['image'], services['ops']['image'] = server_image, ops_image
    server_env = environment(items['server'])
    for key in REQUIRED_ENV:
        need(server_env.get(key), 'server environment field ' + key)
    if (server_env['FUMINIWA_RUNTIME_MODE'] != 'production'
            or server_env['FUMINIWA_SYNC_V2_POSTGRES_HOST'] != 'postgres'
            or server_env['FUMINIWA_SYNC_V2_BIND'] != '0.0.0.0:8092'):
        raise RenderError('unexpected server routing/runtime')
    runtime_dir = None
    allowed = {'postgres': {'/var/lib/postgresql/data'},
               'server': {'/run/secrets/' + name for name in SERVER_SECRETS},
               'edge': {'/data', '/config', '/etc/caddy/Caddyfile'},
               'ops': {'/var/run/docker.sock', '/backups', '/run/secrets/backup-aes256.key',
                       '/run/secrets/backup-config.json', '/run/secrets/ops-ui-password'}}
    for role, item in items.items():
        for m in item['Mounts']:
            if m['Type'] == 'tmpfs':
                continue
            if m['Destination'] not in allowed[role]:
                raise RenderError('unsupported mount in ' + role)
    for role, mounts in EXTERNAL_MOUNTS.items():
        for target, name in mounts.items():
            current = mount(items[role], target, 'volume')
            if current.get('Name') != name or type(current.get('RW')) is not bool:
                raise RenderError('unexpected external volume name/permissions')
            base = name + ':' + target
            services[role]['volumes'] = [base + ('' if current['RW'] else ':ro')
                                         if entry == base else entry
                                         for entry in services[role]['volumes']]
    for name in SERVER_SECRETS:
        target = '/run/secrets/' + name
        m = mount(items['server'], target, 'bind')
        if m.get('RW') is not False or server_env[FILE_ENV[name]] != target:
            raise RenderError('unexpected secret mount/reference')
        source = host_path(m['Source'])
        if name != 'google-client-secret':
            parent = str(Path(source).parent)
            if runtime_dir is not None and parent != runtime_dir:
                raise RenderError('runtime secrets do not share a directory')
            runtime_dir = parent
        template['secrets'][name] = {'file': literal(source)}
    template['secrets']['google-client-secret']['file'] = literal(runtime_dir + '/google-client-secret')
    services['server']['secrets'] = list(SERVER_SECRETS)
    old_caddy = mount(items['edge'], '/etc/caddy/Caddyfile', 'bind')
    if old_caddy.get('RW') is not False:
        raise RenderError('Caddyfile must be read-only')
    services['edge']['volumes'].append(literal(bind(caddyfile, '/etc/caddy/Caddyfile')))
    ops_item = items['ops']
    ops_volumes, ops_secrets = [], []
    for target in ('/var/run/docker.sock', '/backups', '/run/secrets/backup-aes256.key', '/run/secrets/backup-config.json'):
        m = mount(ops_item, target, 'bind')
        secret = target.startswith('/run/secrets/')
        if m.get('RW') is not (not secret):
            raise RenderError('unexpected ops mount permissions')
        if secret:
            name = target.rsplit('/', 1)[1]
            template['secrets'][name] = {'file': literal(host_path(m['Source']))}
            ops_secrets.append(name)
        else:
            ops_volumes.append(literal(bind(m['Source'], target, False)))
    template['secrets']['ops-ui-password'] = {'file': literal(host_path(ui_password))}
    services['ops']['secrets'] = ops_secrets + ['ops-ui-password']
    services['ops']['volumes'] = ops_volumes
    # The new ops image supplies the UI; scheduler/security are copied from old ops.
    ops_env = environment(ops_item)
    for key in ('TZ', 'BACKUP_TIME'):
        need(ops_env.get(key), 'ops environment ' + key)
    for key, role in (('POSTGRES_CONTAINER', 'postgres'), ('SERVER_CONTAINER', 'server')):
        if ops_env.get(key, NAMES[role]) != NAMES[role]:
            raise RenderError('unexpected backup container override')
    if not 1024 <= ui_port <= 65535 or not re.fullmatch(r'[A-Za-z0-9.-]+', ui_host):
        raise RenderError('invalid UI host/port')
    services['ops']['environment']['OPS_UI_PORT'] = str(ui_port)
    services['ops']['ports'] = [f'{ui_port}:{ui_port}']
    # UI starts from the image's entrypoint; retain current ops health/security.
    services['ops'].pop('entrypoint', None)
    services['ops'].pop('command', None)
    template['x-casaos']['port_map'] = str(ui_port)
    template['x-casaos']['icon'] = f'http://{ui_host}:{ui_port}/icon.svg'
    return template


def save_validated(document, destination):
    check_volume_contract(document)
    contents = dump_yaml(document)
    destination = Path(destination)
    # Write a private candidate beside the output; only replace after config -q.
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', newline='\n',
                                     suffix='.yml', prefix='.app-compose-',
                                     dir=destination.parent, delete=False) as candidate:
        path = Path(candidate.name)
        candidate.write(contents)
    try:
        result = subprocess.run(['docker', 'compose', '--env-file', '/dev/null', '-f', str(path),
                                 'config', '-q'], capture_output=True, timeout=60, check=False)
        if result.returncode:
            raise RenderError('docker compose config -q failed (details withheld)')
        path.replace(destination)
        destination.chmod(0o600)
    finally:
        path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server-image', required=True)
    parser.add_argument('--ops-image', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--ui-password-file', default=BASE + '/ops/ops-ui-password')
    parser.add_argument('--caddyfile', default='/DATA/AppData/fuminiwa-sync/config/Caddyfile')
    parser.add_argument('--ui-host', default='192.168.11.5')
    parser.add_argument('--ui-port', type=int, default=8790)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        server_ref = registry_ref(args.server_image, 'fuminiwa-sync-v2-server')
        ops_ref = registry_ref(args.ops_image, 'fuminiwa-sync-v2-ops')
        items = {role: docker('inspect', name)[0] for role, name in NAMES.items()}
        refs = {items['postgres']['Image'], items['edge']['Image'], server_ref, ops_ref}
        images = {ref: docker('image', 'inspect', ref)[0] for ref in refs}
        document = render(items, images, server_ref, ops_ref, args.ui_password_file,
                          args.caddyfile, args.ui_host, args.ui_port)
        save_validated(document, args.output)
        print('Validated Compose saved (0600): ' + args.output)
    except RenderError as error:
        # Only our fixed field/error descriptions, never Docker's payload.
        print('Compose generation failed: ' + str(error))
        return 1
    except (KeyError, OSError, ValueError, subprocess.SubprocessError):
        # Inspect values and Docker stderr can contain environment/credentials.
        print('Compose generation failed; source runtime/settings/images or Compose validation are incomplete.')
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
