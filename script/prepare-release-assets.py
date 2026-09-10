#!/usr/bin/env python3
"""Create the checksums and ytray-compatible manifest for verified release assets."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
version = (root / 'VERSION').read_text().strip()
assert re.fullmatch(r'\d+\.\d+\.\d+', version), 'Invalid version'
dist = Path(sys.argv[1])
base = os.environ.get('PUBLIC_BASE_URL', 'https://aliyun-oss.yaklang.com/yconnect').rstrip('/')
assets = []
checksums = []
for platform, arch, kind, suffix in [
    ('darwin', 'universal', 'dmg', 'darwin-universal.dmg'),
    ('windows', 'amd64', 'setup', 'windows-x64-setup.exe'),
    ('windows', 'amd64', 'zip', 'windows-x64.zip'),
]:
    name = f'YConnect-{version}-{suffix}'
    path = dist / name
    assert path.is_file() and path.stat().st_size > 0, f'Missing release payload: {name}'
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    checksum = f'{digest}  {name}\n'
    (dist / (name + '.sha256.txt')).write_text(checksum)
    checksums.append(checksum)
    assets.append(dict(platform=platform, architecture=arch, kind=kind, filename=name,
                       url=f'{base}/{version}/{name}', sha256=digest, size=path.stat().st_size))
manifest = dict(schema_version=1, product='yconnect', version=version,
                released_at=subprocess.check_output(['git', '-C', str(root), 'show', '-s', '--format=%cI', 'HEAD'], text=True).strip(),
                release_notes=f'https://github.com/yaklang/yconnect/releases/tag/v{version}', assets=assets)
notes = (root / 'docs' / 'releases' / f'v{version}.md').read_text()
manifest['release_notes_text'] = notes.split('## 下载')[0].strip()
manifest['build_number'] = int(subprocess.check_output([sys.executable, str(root / 'script/version.py'), '--build-number'], text=True))
(dist / 'manifest.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
for name in ['SHA256SUMS', 'SHA256SUMS.txt']:
    (dist / name).write_text(''.join(checksums))
(dist / 'version.txt').write_text(version + '\n')
print(f'Prepared manifest and checksums for {len(assets)} release assets ({version})')
