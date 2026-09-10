#!/usr/bin/env python3
"""Update or check the version mirrors from the root VERSION file."""
import argparse
import pathlib
import plistlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--set', dest='new_version')
parser.add_argument('--build-number', action='store_true')
args = parser.parse_args()
version = args.new_version or (ROOT / 'VERSION').read_text().strip()
if not re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', version):
    raise SystemExit('VERSION must be a stable semantic version')
parts = list(map(int, version.split('.')))
if any(p >= 1000 for p in parts):
    raise SystemExit('Each version component must be below 1000')
if args.build_number:
    print(parts[0] * 1_000_000 + parts[1] * 1_000 + parts[2])
    sys.exit(0)
mirrors = {
    'VERSION': version + '\n',
    'version.txt': version + '\n',
    'darwin/Sources/YConnect/BuildInfo.swift': 'import Foundation\n\nenum BuildInfo {\n    // Kept in sync with VERSION by script/version.py.\n    static let version = "' + version + '"\n}\n',
}
plist = ROOT / 'darwin/Resources/Info.plist'
if args.new_version:
    for name, content in mirrors.items():
        (ROOT / name).write_text(content)
    plist.write_text(re.sub(r'(<key>CFBundleShortVersionString</key>\s*<string>)[^<]+', lambda m: m[1] + version, plist.read_text()))
else:
    for name, content in mirrors.items():
        if (ROOT / name).read_text() != content:
            raise SystemExit(f'{name} differs from VERSION; run script/version.py --set {version}')
    if plistlib.loads(plist.read_bytes())['CFBundleShortVersionString'] != version:
        raise SystemExit('Info.plist differs from VERSION')
print(f'Version synchronized: {version}')
