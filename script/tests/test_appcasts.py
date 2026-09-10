import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('appcasts', ROOT / 'script/sign-appcasts.py')
appcasts = importlib.util.module_from_spec(spec); spec.loader.exec_module(appcasts)

class AppcastTests(unittest.TestCase):
    def test_real_eddsa_signatures_platform_versions_and_tamper_rejection(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); key = root / 'key.pem'
            subprocess.run(['openssl', 'genpkey', '-algorithm', 'ED25519', '-out', str(key)], check=True)
            public = subprocess.check_output(['openssl', 'pkey', '-in', str(key), '-pubout', '-outform', 'DER'])[12:]
            version = (ROOT / 'VERSION').read_text().strip()
            for suffix in ['darwin-universal.dmg', 'windows-x64-setup.exe', 'windows-x64.zip']:
                (root / f'YConnect-{version}-{suffix}').write_bytes(b'test payload - not executable')
            subprocess.run(['python3', str(ROOT / 'script/prepare-release-assets.py'), str(root)], check=True, capture_output=True)
            appcasts.generate(root, key.read_text(), base64.b64encode(public).decode())
            ns = {'s': appcasts.NS}
            mac = ET.parse(root / 'appcast-macos.xml').getroot().find('channel/item')
            win = ET.parse(root / 'appcast-windows.xml').getroot().find('channel/item')
            manifest = json.loads((root / 'manifest.json').read_text())
            self.assertEqual(mac.find('s:version', ns).text, str(manifest['build_number']))
            self.assertEqual(win.find('s:version', ns).text, version)
            self.assertIn('/YCONNECTUPDATE=1', win.find('enclosure').attrib[f'{{{appcasts.NS}}}installerArguments'])
            self.assertEqual(len(base64.b64decode(mac.find('enclosure').attrib[f'{{{appcasts.NS}}}edSignature'])), 64)
            # Feed generation must stop on a mismatched private key or altered payload.
            with self.assertRaises(ValueError): appcasts.generate(root, key.read_text(), base64.b64encode(b'x'*32).decode())
            (root / f'YConnect-{version}-darwin-universal.dmg').write_bytes(b'tampered')
            with self.assertRaises(ValueError): appcasts.generate(root, key.read_text(), base64.b64encode(public).decode())

    def test_build_order_is_independent_of_ci_run_number(self):
        def build(version):
            return int(subprocess.check_output(['python3', str(ROOT/'script/version.py'), '--set', version, '--build-number']))
        self.assertLess(build('0.9.9'), build('0.10.0'))
        self.assertLess(build('0.99.999'), build('1.0.0'))
