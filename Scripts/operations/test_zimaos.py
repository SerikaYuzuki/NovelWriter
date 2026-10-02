import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('render', ROOT / 'SyncServerV2/zimaos/render_app_compose.py')
render = importlib.util.module_from_spec(spec)
spec.loader.exec_module(render)
SERVER_REF = '127.0.0.1:5000/fuminiwa-sync-v2-server:role-split-20261003'
OPS_REF = '127.0.0.1:5000/fuminiwa-sync-v2-ops:ops-ui-20261003'


def fixture():
    items = {}
    for index, (role, name) in enumerate(render.NAMES.items()):
        items[role] = {'Name': '/' + name, 'Image': 'sha256:' + str(index) * 64,
                       'State': {'Running': True}, 'Config': {'Env': ['PATH=/usr/bin'],
                       'Healthcheck': {'Test': ['CMD-SHELL', 'code=$(probe); test "$code" = 200'],
                                      'Interval': 5000000000, 'Timeout': 5000000000, 'Retries': 12},
                       'User': '10001' if role == 'server' else '',
                       'Entrypoint': ['/usr/local/bin/server'] if role == 'server' else ['/entrypoint']},
                       'HostConfig': {'ReadonlyRootfs': role != 'postgres', 'CapDrop': ['ALL'],
                                      'SecurityOpt': ['no-new-privileges:true'],
                                      'Tmpfs': {'/tmp': 'rw,noexec,nosuid,size=16m'},
                                      'LogConfig': {'Type': 'json-file', 'Config': {'max-size': '10m'}}},
                       'Mounts': []}
    env = {key: 'configured-value' for key in render.REQUIRED_ENV}
    env.update(FUMINIWA_RUNTIME_MODE='production', FUMINIWA_SYNC_V2_POSTGRES_HOST='postgres',
               FUMINIWA_SYNC_V2_BIND='0.0.0.0:8092', RUST_LOG='info', SPECIAL_LITERAL='literal${UNSET}$value')
    for name in render.SERVER_SECRETS:
        target = '/run/secrets/' + name
        env[render.FILE_ENV[name]] = target
        source = render.BASE + '/runtime-secrets/' + name
        if name == 'google-client-secret':
            source = render.BASE + '/releases/browser-auth-20260927/' + name
        items['server']['Mounts'].append({'Type': 'bind', 'Source': source, 'Destination': target, 'RW': False})
    items['server']['Config']['Env'] = [k + '=' + v for k, v in env.items()]
    items['ops']['Config']['Env'] += ['TZ=Asia/Tokyo', 'BACKUP_TIME=03:17']
    for role, target, volume in [('postgres', '/var/lib/postgresql/data', 'data'),
                                ('edge', '/data', 'caddy-data'), ('edge', '/config', 'caddy-config')]:
        items[role]['Mounts'].append({'Type': 'volume', 'Destination': target,
                                     'Name': 'fuminiwa-sync-v2-role-split-' + volume, 'RW': True})
    items['edge']['Mounts'].append({'Type': 'bind', 'Source': render.BASE + '/source/Caddyfile',
                                    'Destination': '/etc/caddy/Caddyfile', 'RW': False})
    for target, source, rw in [('/var/run/docker.sock', '/var/run/docker.sock', True),
                               ('/backups', render.BASE + '/operational-backups/daily', True),
                               ('/run/secrets/backup-config.json', render.BASE + '/operational-backups/backup-config.json', False),
                               ('/run/secrets/backup-aes256.key', render.BASE + '/backup-keys/backup-aes256.key', False)]:
        items['ops']['Mounts'].append({'Type': 'bind', 'Source': source, 'Destination': target, 'RW': rw})
    images = {items['postgres']['Image']: {'RepoDigests': ['postgres@sha256:' + 'a' * 64]},
              items['edge']['Image']: {'RepoDigests': ['caddy@sha256:' + 'b' * 64]},
              SERVER_REF: {'Id': items['server']['Image']}, OPS_REF: {'Id': 'sha256:' + 'f' * 64}}
    return items, images


class RenderTests(unittest.TestCase):
    def document(self, items=None, images=None):
        defaults = fixture()
        return render.render(items or defaults[0], images or defaults[1], SERVER_REF, OPS_REF,
                             render.BASE + '/ops/ops-ui-password',
                             '/DATA/AppData/fuminiwa-sync/config/Caddyfile', '192.168.11.5', 8790)

    def test_expected_services_volumes_digests_and_paths_no_secret_reads(self):
        # Any attempted content read outside the template fails this test.
        original = Path.read_text
        def guarded(path, *args, **kwargs):
            self.assertEqual(path, render.HERE / 'app-compose.template.yml')
            return original(path, *args, **kwargs)
        with patch.object(Path, 'read_text', guarded), patch.object(Path, 'read_bytes', side_effect=AssertionError('secret read')):
            document = self.document()
        self.assertEqual(set(document['services']), {'postgres', 'server', 'edge', 'ops'})
        for role, name in render.NAMES.items():
            self.assertEqual(document['services'][role]['container_name'], name)
            self.assertEqual(document['services'][role]['restart'], 'unless-stopped')
        self.assertTrue(all(v['external'] for v in document['volumes'].values()))
        self.assertEqual(document['services']['postgres']['image'], 'postgres@sha256:' + 'a' * 64)
        self.assertEqual(document['services']['edge']['image'], 'caddy@sha256:' + 'b' * 64)
        self.assertEqual(document['services']['server']['image'], SERVER_REF)
        self.assertEqual(document['services']['server']['environment']['SPECIAL_LITERAL'], 'literal$${UNSET}$$value')
        self.assertIn('$$code', document['services']['server']['healthcheck']['test'][1])
        self.assertEqual(document['secrets']['google-client-secret']['file'], render.BASE + '/runtime-secrets/google-client-secret')
        self.assertEqual(document['services']['edge']['volumes'][-1]['source'], '/DATA/AppData/fuminiwa-sync/config/Caddyfile')
        self.assertEqual(document['services']['ops']['ports'], ['8790:8790'])
        self.assertEqual(document['x-casaos']['main'], 'ops')
        self.assertNotIn('migrator', document['services']['server']['depends_on'])

    def test_missing_values_inline_secrets_and_unexpected_mount_fail(self):
        mutations = [lambda i, m: i['server']['Config'].update(Env=['PATH=/usr/bin']),
                     lambda i, m: i['server']['Mounts'].pop(),
                     lambda i, m: m[i['postgres']['Image']].update(RepoDigests=[]),
                     lambda i, m: m[SERVER_REF].update(Id='sha256:wrong'),
                     lambda i, m: i['server']['Config']['Env'].append('API_SECRET=never-output-this'),
                     lambda i, m: i['server']['Mounts'].append({'Type': 'bind', 'Destination': '/host-root'}),
                     lambda i, m: i['edge']['HostConfig'].update(ReadonlyRootfs=False),
                     lambda i, m: i['postgres']['Mounts'][0].update(Name='wrong-data'),
                     lambda i, m: i['ops']['State'].update(Running=False)]
        for mutate in mutations:
            items, images = fixture()
            mutate(items, images)
            with self.subTest(mutation=mutate), self.assertRaises(render.RenderError):
                self.document(items, images)

    def test_validate_before_replace_keeps_previous_output_on_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / 'compose.yml'
            destination.write_text('previous')
            with patch.object(render.subprocess, 'run') as run:
                run.return_value.returncode = 1
                with self.assertRaises(render.RenderError):
                    render.save_validated(self.document(), destination)
                self.assertEqual(destination.read_text(), 'previous')
                run.return_value.returncode = 0
                render.save_validated(self.document(), destination)
                self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
                command = run.call_args.args[0]
                self.assertEqual(command[:4], ['docker', 'compose', '--env-file', '/dev/null'])
                self.assertEqual(command[-2:], ['config', '-q'])
                self.assertEqual(set(json.loads(destination.read_text())['services']), set(render.NAMES))
            self.assertEqual([p.name for p in Path(temporary).iterdir()], ['compose.yml'])

    def test_cli_uses_fake_docker_inspect_json_and_config_validation(self):
        items, images = fixture()
        data = {item['Name'][1:]: [item] for item in items.values()}
        data.update({key: [value] for key, value in images.items()})
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture_path = root / 'inspect.json'
            fixture_path.write_text(json.dumps(data))
            fake = root / 'docker'
            fake.write_text('#!/usr/bin/env python3\nimport json,os,sys\na=sys.argv[1:]\nif a[0]=="compose":\n sys.exit(0 if a[-2:]==["config","-q"] else 9)\nprint(json.dumps(json.load(open(os.environ["FAKE_INSPECT"]))[a[-1]]))\n')
            fake.chmod(0o700)
            destination = root / 'output.yml'
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'], FAKE_INSPECT=str(fixture_path))
            result = subprocess.run([os.sys.executable, str(render.HERE / 'render_app_compose.py'),
                                     '--server-image', SERVER_REF, '--ops-image', OPS_REF,
                                     '--output', str(destination)], capture_output=True, env=env)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(json.loads(destination.read_text()), self.document())
            # A missing secret mount fails without ever printing inspect contents.
            data[render.NAMES['server']][0]['Mounts'].pop()
            fixture_path.write_text(json.dumps(data))
            before = destination.read_bytes()
            result = subprocess.run([os.sys.executable, str(render.HERE / 'render_app_compose.py'),
                                     '--server-image', SERVER_REF, '--ops-image', OPS_REF,
                                     '--output', str(destination)], capture_output=True, env=env)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(destination.read_bytes(), before)
            self.assertNotIn(b'configured-value', result.stdout + result.stderr)

    def test_prepare_only_builds_ops_tags_captured_server_and_pushes_without_mutation(self):
        items, images = fixture()
        data = {item['Name'][1:]: [item] for item in items.values()}
        data.update({key: [value] for key, value in images.items()})
        data['fuminiwa-registry'] = [{'State': {'Running': True},
                                     'HostConfig': {'RestartPolicy': {'Name': 'unless-stopped'},
                                                    'PortBindings': {'5000/tcp': [{'HostIp': '127.0.0.1', 'HostPort': '5000'}]}},
                                     'Mounts': [{'Name': 'fuminiwa-registry-data', 'Destination': '/var/lib/registry'}]}]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'inspect.json').write_text(json.dumps(data))
            fake = root / 'docker'
            fake.write_text('''#!/usr/bin/env python3
import json,os,sys
a=sys.argv[1:]
with open(os.environ['FAKE_COMMANDS'], 'a') as out:
 out.write(json.dumps({'args':a,'config':os.environ.get('DOCKER_CONFIG')})+'\\n')
data=json.load(open(os.environ['FAKE_INSPECT']))
if a[0] in ('compose','buildx','build','tag','push'):
 sys.exit(0)
if a[0]=='inspect' and '--format' in a:
 print(data[a[1]][0]['Image'])
else:
 print(json.dumps(data[a[-1]]))
''')
            fake.chmod(0o700)
            destination = root / 'output.yml'
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                       FAKE_INSPECT=str(root / 'inspect.json'), FAKE_COMMANDS=str(root / 'commands.jsonl'),
                       FUMINIWA_PREPARE_DOCKER_CONFIG=str(root / 'docker-config'))
            result = subprocess.run(['sh', str(render.HERE / 'prepare.sh'), 'role-split-20261003',
                                     'ops-ui-20261003', str(destination)], capture_output=True, env=env)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            commands = [json.loads(line) for line in (root / 'commands.jsonl').read_text().splitlines()]
            self.assertTrue(all(c['config'] == str(root / 'docker-config') for c in commands))
            args = [c['args'] for c in commands]
            builds = [a for a in args if a[0] == 'build']
            self.assertEqual(len(builds), 1)
            self.assertIn(str(ROOT / 'SyncServerV2/ops/Dockerfile'), builds[0])
            self.assertIn(['tag', items['server']['Image'], SERVER_REF], args)
            self.assertIn(['push', SERVER_REF], args)
            self.assertIn(['push', OPS_REF], args)
            self.assertTrue(all(a[0] not in ('stop', 'start', 'rename', 'rm', 'update', 'run') for a in args))
            self.assertEqual(json.loads(destination.read_text()), self.document())


if __name__ == '__main__':
    unittest.main()
