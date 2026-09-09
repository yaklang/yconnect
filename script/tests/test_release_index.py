import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import os

ROOT = Path(__file__).resolve().parents[2]


class ReleaseIndexTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        version = '0.3.0'
        self.manifest = dict(schema_version=1, product='yconnect', version=version,
                             released_at='2026-09-09T00:00:00Z', assets=[])
        for platform, architecture, kind, name in [('darwin', 'universal', 'dmg', 'a.dmg'), ('windows', 'amd64', 'setup', 'b.exe'), ('windows', 'amd64', 'zip', 'c.zip')]:
            self.manifest['assets'].append(dict(platform=platform, architecture=architecture, kind=kind, filename=name,
                url=f'https://aliyun-oss.yaklang.com/yconnect/{version}/{name}', sha256='a' * 64, size=100))
        self.previous = dict(schema_version=1, product='yconnect', latest='0.2.0',
                             versions=[dict(version='0.2.0', marker='retain old release')])

    def run_index(self, manifest=None, previous=None):
        (self.root / 'manifest.json').write_text(json.dumps(manifest or self.manifest))
        (self.root / 'previous.json').write_text(json.dumps(previous or self.previous))
        return subprocess.run(['bash', str(ROOT / 'script/prepare-release-index.sh'), '0.3.0',
                               str(self.root / 'manifest.json'), str(self.root / 'out')],
                              env={**os.environ, 'EXISTING_RELEASES_FILE': str(self.root / 'previous.json')},
                              capture_output=True, text=True)

    def test_publishes_consistent_pointers_and_preserves_history_on_retry(self):
        result = self.run_index()
        self.assertEqual(result.returncode, 0, result.stderr)
        out = self.root / 'out'
        history = json.loads((out / 'releases.json').read_text())
        self.assertEqual(history['latest'], '0.3.0')
        self.assertEqual(history['versions'], [self.manifest] + self.previous['versions'])
        for name in ['version.txt', 'latest.txt', 'latest-version.txt']:
            self.assertEqual((out / name).read_text(), '0.3.0\n')
        self.assertEqual(json.loads((out / 'latest.json').read_text()), self.manifest)
        result = self.run_index(previous=history)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((out / 'releases.json').read_text()), history)

    def test_rejects_missing_platform_duplicate_platform_and_bad_hash(self):
        for mutation in ['missing', 'duplicate', 'hash']:
            with self.subTest(mutation=mutation):
                manifest = copy.deepcopy(self.manifest)
                if mutation == 'missing': manifest['assets'].pop()
                if mutation == 'duplicate': manifest['assets'][2] = manifest['assets'][1]
                if mutation == 'hash': manifest['assets'][0]['sha256'] = 'bad'
                self.assertNotEqual(self.run_index(manifest).returncode, 0)

    def test_rejects_other_product_unsafe_paths_and_wrong_download_url(self):
        for mutation in ['product', 'path', 'url']:
            with self.subTest(mutation=mutation):
                manifest = copy.deepcopy(self.manifest)
                if mutation == 'product': manifest['product'] = 'ytray'
                if mutation == 'path': manifest['assets'][0]['filename'] = '../a.dmg'
                if mutation == 'url': manifest['assets'][0]['url'] += '.wrong'
                self.assertNotEqual(self.run_index(manifest).returncode, 0)

    def test_rejects_downgrade_and_invalid_existing_index(self):
        previous = copy.deepcopy(self.previous)
        previous['latest'] = '0.4.0'
        self.assertNotEqual(self.run_index(previous=previous).returncode, 0)
        previous['latest'] = '0.2.0'
        previous['product'] = 'ytray'
        self.assertNotEqual(self.run_index(previous=previous).returncode, 0)


if __name__ == '__main__':
    unittest.main()
