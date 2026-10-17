#!/usr/bin/env python3
"""Select an installed Xcode with the iOS 26 SDK; never download a toolchain."""
import os
from pathlib import Path
import re
import subprocess

candidates = []
for app in sorted(Path('/Applications').glob('Xcode*.app')):
    developer = app / 'Contents/Developer'
    binary = developer / 'usr/bin/xcodebuild'
    if not binary.exists():
        continue
    env = dict(os.environ, DEVELOPER_DIR=str(developer))
    result = subprocess.run([str(binary), '-version'], capture_output=True, text=True, env=env)
    match = re.search(r'Xcode (\d+)(?:\.(\d+))?(?:\.(\d+))?', result.stdout)
    if result.returncode == 0 and match:
        version = tuple(int(part or 0) for part in match.groups())
        if version[0] >= 26:
            candidates.append((version, developer))
if not candidates:
    raise SystemExit('Xcode 26 or newer is required for native Liquid Glass. Select a GitHub macOS runner with that Xcode installed.')
version, developer = max(candidates)
if 'GITHUB_ENV' in os.environ:
    with open(os.environ['GITHUB_ENV'], 'a', encoding='utf-8') as output:
        output.write('DEVELOPER_DIR=' + str(developer) + '\n')
print('Selected Xcode ' + '.'.join(map(str, version)) + ': ' + str(developer))
