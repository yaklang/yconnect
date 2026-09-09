"""Exercise publication ordering and immutable retries using a local OSS/CDN fixture."""
import functools
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = self.root / 'store'
        self.store.mkdir()
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(QuietHandler, directory=str(self.store)))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.version = (ROOT / 'VERSION').read_text().strip()
        (self.root / 'VERSION').write_text(self.version + '\n')
        (self.root / 'script').symlink_to(ROOT / 'script', target_is_directory=True)
        self.dist = self.root / 'release'
        self.dist.mkdir()
        for suffix in ['darwin-universal.dmg', 'windows-x64-setup.exe', 'windows-x64.zip']:
            (self.dist / f'YConnect-{self.version}-{suffix}').write_bytes(('fixture-' + suffix).encode())
        bindir = self.root / 'bin'
        bindir.mkdir()
        mock = bindir / 'ossutil'
        mock.write_text('''#!/usr/bin/env python3
import os, pathlib, shutil, sys
args = iter(sys.argv[2:]); positional = []
for arg in args:
    if arg in ['-e', '-i', '-k', '--meta']: next(args)
    elif arg != '-f': positional.append(arg)
def local(value):
    if value.startswith('oss://yaklang/'):
        return pathlib.Path(os.environ['MOCK_OSS_ROOT']) / value[len('oss://yaklang/'):]
    return pathlib.Path(value)
if sys.argv[1] == 'ls':
    if local(positional[0]).exists(): print(positional[0])
elif sys.argv[1] == 'cp':
    source, destination = map(local, positional)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
else: raise SystemExit('Unexpected mock OSS operation')
''')
        mock.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(bindir) + os.pathsep + os.environ['PATH'],
                    'MOCK_OSS_ROOT': str(self.store), 'OSS_ACCESS_KEY_ID': 'fixture-id',
                    'OSS_ACCESS_KEY_SECRET': 'fixture-secret', 'CDN_VERIFY_ATTEMPTS': '1',
                    'PUBLIC_BASE_URL': f'http://127.0.0.1:{self.server.server_port}/yconnect'}
        subprocess.run(['python3', str(ROOT / 'script/prepare-release-assets.py'), str(self.dist)], env=self.env, check=True, capture_output=True)

    def publish(self):
        return subprocess.run(['bash', str(ROOT / 'script/publish-oss.sh'), 'release', 'indexes'],
                              cwd=self.root, env=self.env, capture_output=True, text=True, timeout=30)

    def test_first_publication_and_retry_verify_all_downloads_and_version_pointers(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('CDN raw-response verified: latest.json', result.stdout)
        public = self.store / 'yconnect'
        self.assertEqual((public / 'version.txt').read_text(), self.version + '\n')
        history = json.loads((public / 'releases.json').read_text())
        self.assertEqual(history['latest'], self.version)
        self.assertEqual(len(history['versions']), 1)
        for path in self.dist.iterdir():
            self.assertEqual((public / self.version / path.name).read_bytes(), path.read_bytes())
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((public / 'releases.json').read_text()), history)

    def test_changed_immutable_object_stops_without_moving_indexes(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        public = self.store / 'yconnect'
        previous = (public / 'latest.json').read_bytes()
        object_path = next((public / self.version).glob('*.dmg'))
        object_path.write_bytes(b'previously published different bytes')
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Refusing to overwrite', result.stderr)
        self.assertEqual((public / 'latest.json').read_bytes(), previous)
        self.assertEqual(object_path.read_bytes(), b'previously published different bytes')
