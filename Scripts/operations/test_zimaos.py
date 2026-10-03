import copy
import importlib.util
import json
import os
import re
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
SERVER_CHECK = ('code="$(curl --silent --show-error --output /dev/null '
                "--write-out '%{http_code}' --header 'x-fuminiwa-client-version: 0.1.0' "
                'http://127.0.0.1:8092/v1/auth/capabilities || true)"; test "$code" = 200')


def fixture():
    items = {}
    for index, (role, name) in enumerate(render.NAMES.items()):
        items[role] = {'Name': '/' + name, 'Image': 'sha256:' + str(index) * 64,
                       'State': {'Running': True}, 'Config': {'Env': ['PATH=/usr/bin'],
                       'Healthcheck': {'Test': ['CMD', 'ops-healthcheck'],
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
               FUMINIWA_SYNC_V2_BIND='0.0.0.0:8092', RUST_LOG='info', SPECIAL_LITERAL='concrete-value')
    items['server']['Config']['Healthcheck']['Test'] = ['CMD-SHELL', SERVER_CHECK]
    items['postgres']['Config']['Healthcheck']['Test'] = ['CMD-SHELL', 'pg_isready -U fuminiwa_sync_v2_bootstrap -d fuminiwa_sync_v2']
    items['edge']['Config']['Healthcheck']['Test'] = ['CMD-SHELL', "wget -q -S --spider http://127.0.0.1:2019/config/ 2>&1 | grep -Eq 'HTTP/[0-9.]+ 200'"]
    items['edge']['Config']['Env'].append('XDG_CONFIG_HOME=/config')
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
        self.assertEqual(document['volumes'], {
            'fuminiwa-sync-v2-role-split-' + suffix: {
                'name': 'fuminiwa-sync-v2-role-split-' + suffix, 'external': True}
            for suffix in ('data', 'caddy-data', 'caddy-config')})
        self.assertEqual(document['services']['postgres']['volumes'],
                         ['fuminiwa-sync-v2-role-split-data:/var/lib/postgresql/data'])
        self.assertEqual(document['services']['edge']['volumes'][:2],
                         ['fuminiwa-sync-v2-role-split-caddy-data:/data',
                          'fuminiwa-sync-v2-role-split-caddy-config:/caddy-config'])
        self.assertEqual(document['services']['edge']['environment']['XDG_CONFIG_HOME'], '/caddy-config')
        self.assertEqual(document['services']['edge']['volumes'][-1]['type'], 'bind')
        self.assertTrue(all(v['type'] == 'bind' for v in document['services']['ops']['volumes']))
        self.assertEqual(document['services']['server']['healthcheck']['interval'], '5s')
        self.assertEqual(document['services']['server']['healthcheck']['timeout'], '5s')
        self.assertEqual(document['services']['postgres']['image'], 'postgres@sha256:' + 'a' * 64)
        self.assertEqual(document['services']['edge']['image'], 'caddy@sha256:' + 'b' * 64)
        self.assertEqual(document['services']['server']['image'], SERVER_REF)
        self.assertEqual(document['services']['server']['environment']['SPECIAL_LITERAL'], 'concrete-value')
        self.assertTrue(document['services']['server']['healthcheck']['test'][1].startswith('test "$$(curl '))
        self.assertNotIn('$$code', document['services']['server']['healthcheck']['test'][1])
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
                self.assertEqual(destination.read_text(), render.dump_yaml(self.document()))
                self.assertTrue(destination.read_text().startswith('"services":\n'))
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
            self.assertEqual(destination.read_text(), render.dump_yaml(self.document()))
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
            self.assertEqual(destination.read_text(), render.dump_yaml(self.document()))

    def test_yaml_output_quotes_strings_and_preserves_scalar_types(self):
        document = {'services': {'ops': {
            'environment': {'ON': 'yes', 'NUMBER': '0123', 'EMPTY': '',
                            'SPECIAL': 'quote" slash\\\nnew: node # comment\t${VALUE}',
                            'UNICODE': 'ふみにわ🌱\x85\u2028\u2029\x7f'},
            'volumes': ['external:/data:ro', {'type': 'bind', 'source': '/a: b#c', 'read_only': True}],
            'healthcheck': {'interval': '5s', 'retries': 12},
            'read_only': False, 'null': None, 'empty_map': {}, 'empty_list': []}}}
        expected = r'''"services":
  "ops":
    "environment":
      "ON": "yes"
      "NUMBER": "0123"
      "EMPTY": ""
      "SPECIAL": "quote\" slash\\\nnew: node # comment\t${VALUE}"
      "UNICODE": "ふみにわ🌱\u0085\u2028\u2029\u007f"
    "volumes":
      - "external:/data:ro"
      -
        "type": "bind"
        "source": "/a: b#c"
        "read_only": true
    "healthcheck":
      "interval": "5s"
      "retries": 12
    "read_only": false
    "null": null
    "empty_map": {}
    "empty_list": []
'''
        self.assertEqual(render.dump_yaml(document), expected)
        for invalid in ({1: 'key'}, {'value': 1.5}, {'value': float('nan')}, {'value': '\ud800'}):
            with self.subTest(invalid=invalid), self.assertRaises(render.RenderError):
                render.dump_yaml(invalid)

    def test_read_only_named_volume_uses_short_ro_suffix(self):
        items, images = fixture()
        items['postgres']['Mounts'][0]['RW'] = False
        document = self.document(items, images)
        self.assertEqual(document['services']['postgres']['volumes'],
                         ['fuminiwa-sync-v2-role-split-data:/var/lib/postgresql/data:ro'])
        render.check_volume_contract(document)

    def test_self_check_rejects_long_volume_wrong_names_and_bind_substitution(self):
        original = self.document()
        name = 'fuminiwa-sync-v2-role-split-data'
        mutations = [lambda d: d['services']['postgres'].update(volumes=[{'type': 'volume', 'source': name, 'target': '/var/lib/postgresql/data'}]),
                     lambda d: d['volumes'][name].update(name='wrong-name'),
                     lambda d: d['volumes'].update(db=d['volumes'].pop(name)),
                     lambda d: d['volumes'][name].update(external=False),
                     lambda d: d['volumes'][name].update(external=1),
                     lambda d: d['volumes'].update({name: None}),
                     lambda d: d['services']['postgres'].update(volumes=[]),
                     lambda d: d['services']['postgres'].update(volumes=['db:/var/lib/postgresql/data']),
                     lambda d: d['services']['postgres'].update(volumes=[{'type': 'bind', 'source': '/tmp/casaos/db', 'target': '/var/lib/postgresql/data'}])]
        for mutate in mutations:
            document = copy.deepcopy(original)
            mutate(document)
            with self.subTest(mutation=mutate), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary) / 'compose.yml'
                output.write_text('previous')
                with patch.object(render.subprocess, 'run') as compose:
                    with self.assertRaises(render.RenderError):
                        render.save_validated(document, output)
                    compose.assert_not_called()
                self.assertEqual(output.read_text(), 'previous')
                self.assertEqual(list(Path(temporary).iterdir()), [output])

    def test_health_durations_are_readable_exact_and_never_ns(self):
        for value, expected in ((5_000_000_000, '5s'), (300_000_000_000, '5m'),
                                (3_600_000_000_000, '1h'), (1_500_000_000, '1.5s'),
                                (250_000_000, '250ms'), (1000, '1us'), (123, '0.123us')):
            self.assertEqual(render.duration(value), expected)
        for value in (0, -1, True, '5000000000', 1.5):
            with self.assertRaises(render.RenderError):
                render.duration(value)
        items, images = fixture()
        items['server']['Config']['Healthcheck'].update(StartPeriod=10_000_000_000, StartInterval=2_000_000_000)
        document = self.document(items, images)
        self.assertEqual(document['services']['server']['healthcheck']['start_period'], '10s')
        self.assertEqual(document['services']['server']['healthcheck']['start_interval'], '2s')

    def test_healthcheck_keeps_semantics_after_two_interpolation_passes(self):
        def interpolate(command):
            # Independent model of the observed $$ / $name / ${name} handling.
            return re.sub(r'\$\$|\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*',
                          lambda match: '$' if match[0] == '$$' else '', command)
        document = self.document()
        generated = document['services']['server']['healthcheck']['test'][1]
        final = interpolate(interpolate(generated))
        broken = interpolate(interpolate(SERVER_CHECK.replace('$', '$$')))
        self.assertIn('test "" = 200', broken)
        self.assertIn('test "$(curl ', final)
        with tempfile.TemporaryDirectory() as temporary:
            fake = Path(temporary) / 'curl'
            fake.write_text('#!/usr/bin/env python3\nimport os,sys\nsys.stdout.write(os.environ["FAKE_HTTP_CODE"])\nsys.exit(int(os.environ["FAKE_CURL_EXIT"]))\n')
            fake.chmod(0o700)
            for output, exit_code in (('200', 0), ('200', 7), ('401', 0), ('500', 0), ('000', 7), ('', 7)):
                env = dict(os.environ, PATH=temporary + os.pathsep + os.environ['PATH'],
                           FAKE_HTTP_CODE=output, FAKE_CURL_EXIT=str(exit_code))
                original = subprocess.run(['sh', '-c', SERVER_CHECK], env=env, capture_output=True)
                updated = subprocess.run(['sh', '-c', final], env=env, capture_output=True)
                self.assertEqual(updated.returncode, original.returncode, (output, exit_code))
                self.assertEqual(updated.returncode == 0, output == '200')
                if output == '200':
                    self.assertNotEqual(subprocess.run(['sh', '-c', broken], env=env, capture_output=True).returncode, 0)
        for role in ('postgres', 'edge', 'ops'):
            self.assertEqual(document['services'][role]['healthcheck']['test'], fixture()[0][role]['Config']['Healthcheck']['Test'])
        braced = SERVER_CHECK.replace('"$code"', '"${code}"')
        self.assertEqual(render.variable_free_healthcheck(['CMD-SHELL', braced]),
                         render.variable_free_healthcheck(['CMD-SHELL', SERVER_CHECK]))

    def test_unknown_healthcheck_variables_and_environment_references_fail_generation(self):
        for command in ('test "$unknown" = 200', 'code=$(probe); test "$code" = 200',
                        SERVER_CHECK + '; echo done', SERVER_CHECK.replace('curl --silent', 'curl $OPTIONS --silent'),
                        'echo "$1"', 'echo "$$"', 'code=$(curl); test $code = 200'):
            items, images = fixture()
            items['server']['Config']['Healthcheck']['Test'] = ['CMD-SHELL', command]
            with self.subTest(command=command), self.assertRaises(render.RenderError):
                self.document(items, images)
        for value in ('literal${UNSET}', '$value', '$1'):
            items, images = fixture()
            items['server']['Config']['Env'].append('UNSUPPORTED_LITERAL=' + value)
            with self.subTest(value=value), self.assertRaises(render.RenderError):
                self.document(items, images)

    def test_self_check_rejects_variable_references_and_config_targets_before_publish(self):
        mutations = [lambda d: d['services']['server']['healthcheck'].update(test=['CMD-SHELL', 'test "$$code" = 200']),
                     lambda d: d['services']['ops']['environment'].update(TEST='$${VALUE}'),
                     lambda d: d['services']['ops']['environment'].update(TEST='${VALUE}'),
                     lambda d: d['services']['ops']['volumes'].append({'type': 'bind', 'source': '/tmp/config', 'target': '/config'}),
                     lambda d: d['services']['ops']['volumes'].append('fuminiwa-sync-v2-role-split-caddy-config:/config')]
        for mutate in mutations:
            document = self.document()
            mutate(document)
            with self.subTest(mutation=mutate), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary) / 'compose.yml'
                output.write_text('previous')
                with patch.object(render.subprocess, 'run') as compose:
                    with self.assertRaises(render.RenderError):
                        render.save_validated(document, output)
                    compose.assert_not_called()
                self.assertEqual(output.read_text(), 'previous')
        contents = render.dump_yaml(self.document())
        self.assertIsNone(re.search(r'\$\$[A-Za-z_{]|\$\{', contents))

    def test_caddy_config_volume_moves_without_changing_volume_or_relative_contents(self):
        items, images = fixture()
        old = next(m for m in items['edge']['Mounts'] if m['Destination'] == '/config')
        document = self.document(items, images)
        ref = document['services']['edge']['volumes'][1]
        self.assertEqual(ref, old['Name'] + ':/caddy-config')
        # XDG_CONFIG_HOME/caddy is the same root-relative caddy directory,
        # so autosave.json is neither copied nor renamed inside the volume.
        self.assertEqual(document['services']['edge']['environment']['XDG_CONFIG_HOME'] + '/caddy/autosave.json',
                         '/caddy-config/caddy/autosave.json')
        old['Destination'] = '/caddy-config'
        items['edge']['Config']['Env'][-1] = 'XDG_CONFIG_HOME=/caddy-config'
        self.assertEqual(self.document(items, images), document)
        old['RW'] = False
        self.assertEqual(self.document(items, images)['services']['edge']['volumes'][1], ref + ':ro')
        old['Name'] = 'wrong-config'
        with self.assertRaises(render.RenderError):
            self.document(items, images)


if __name__ == '__main__':
    unittest.main()
