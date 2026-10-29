"""Publish reviewed local artifacts to the existing public GitHub repository."""
from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REPO = 'imchenhua/QuotaBar'
GH = shutil.which('gh') or str(Path.home() / '.local/bin/gh')


def run(*args):
    return subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--notes-file', type=Path, required=True)
    options = parser.parse_args()
    assert run(GH, 'api', 'user', '--jq', '.login') == 'imchenhua', 'Wrong active GitHub account.'
    repo = json.loads(run(GH, 'repo', 'view', REPO, '--json', 'visibility'))
    assert repo['visibility'] == 'PUBLIC', 'Update downloads require the chosen public repository.'
    assert not run('git', 'status', '--porcelain'), 'Commit reviewed source before publishing.'
    assert run('git', 'branch', '--show-current') == 'main'
    assert run('git', 'remote', 'get-url', 'origin') == 'git@gh-new:imchenhua/QuotaBar.git'
    info = plistlib.loads((ROOT / 'Info.plist').read_bytes())
    assert info.get('QuotaBarUpdatesEnabled'), 'Release must have updates enabled.'
    version = info['CFBundleShortVersionString']
    tag = 'v' + version
    artifacts = ROOT / 'dist' / tag
    expected = {f'QuotaBar-{version}-arm64.zip', 'QuotaBar-arm64.dmg', 'appcast.xml'}
    recorded = {}
    for line in (artifacts / 'SHA256SUMS').read_text().splitlines():
        digest, name = line.split('  ', 1)
        assert name == Path(name).name and name in expected
        assert hashlib.sha256((artifacts / name).read_bytes()).hexdigest() == digest, 'Artifact checksum mismatch.'
        recorded[name] = digest
    assert set(recorded) == expected
    assert not run('git', 'tag', '--list', tag), 'Existing release tag preserved; use a new version.'
    run('git', 'push', 'origin', 'main')
    run('git', 'tag', tag)
    run('git', 'push', 'origin', tag)
    url = run(GH, 'release', 'create', tag, '--repo', REPO, '--verify-tag', '--latest',
              '--title', f'QuotaBar {version}', '--notes-file', options.notes_file.resolve(),
              *(artifacts / name for name in sorted(expected)), artifacts / 'SHA256SUMS')
    for name, digest in recorded.items():
        request = urllib.request.Request(f'https://github.com/{REPO}/releases/download/{tag}/{name}',
                                         headers={'User-Agent': 'QuotaBar-release-verification'})
        with urllib.request.urlopen(request, timeout=60) as response:
            assert hashlib.sha256(response.read()).hexdigest() == digest, 'Public download checksum mismatch.'
    print(f'Published and verified public downloads: {url}')


if __name__ == '__main__':
    main()
