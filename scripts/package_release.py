"""Package an already built app and generate a signed Sparkle feed without Keychain prompts."""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'build/QuotaBar.app'
KEY = Path.home() / '.local/share/quotabar-update-signing/ed25519.key'
SPARKLE = ROOT / 'vendor/Sparkle-2.10.1/bin'


def run(*args):
    return subprocess.run([str(arg) for arg in args], check=True, capture_output=True, text=True)


def main():
    info = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    build = info['CFBundleVersion']
    assert all(c.isdigit() or c == '.' for c in version) and build.isdigit()
    assert info.get('SURequireSignedFeed') and info.get('SUVerifyUpdateBeforeExtraction')
    assert KEY.exists(), 'Missing release signing key; do not generate a replacement for an existing app.'
    assert KEY.stat().st_mode & 0o077 == 0, 'Signing key must be private.'
    public_key = run('swift', ROOT / 'scripts/update_keys.swift').stdout.strip()
    assert public_key == info['SUPublicEDKey'], 'Signing key does not match app public key.'
    run('codesign', '--verify', '--deep', '--strict', APP)
    manifest = json.loads((ROOT / 'support/credential-agent-v1.json').read_text())
    assert hashlib.sha256((ROOT / 'CredentialAgent/main.swift').read_bytes()).hexdigest() == manifest['sourceSHA256']
    assert hashlib.sha256((APP / 'Contents/Resources/credential-agent-v1').read_bytes()).hexdigest() == manifest['binarySHA256']
    output = ROOT / 'dist' / f'v{version}'
    output.mkdir(parents=True, exist_ok=False)
    archive = output / f'QuotaBar-{version}-arm64.zip'
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', APP, archive)
    run(SPARKLE / 'generate_appcast', '--ed-key-file', KEY, '--maximum-deltas', '0',
        '--download-url-prefix', f'https://github.com/imchenhua/QuotaBar/releases/download/v{version}/',
        '--link', 'https://github.com/imchenhua/QuotaBar', output)
    feed = output / 'appcast.xml'
    run(SPARKLE / 'sign_update', '--verify', '--ed-key-file', KEY, feed)
    enclosure = ET.parse(feed).find('./channel/item/enclosure')
    assert enclosure is not None
    signature = enclosure.attrib['{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature']
    assert int(enclosure.attrib['length']) == archive.stat().st_size
    assert enclosure.attrib['url'].endswith('/' + archive.name)
    run(SPARKLE / 'sign_update', '--verify', '--ed-key-file', KEY, archive, signature)
    files = [archive, feed]
    (output / 'SHA256SUMS').write_text(''.join(
        f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n' for path in files))
    print(f'Verified release {version} ({build}): {output}')


if __name__ == '__main__':
    main()
