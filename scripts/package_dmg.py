"""Build a one-click, current-user installer inside a read-only disk image."""
from pathlib import Path
import hashlib
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True, capture_output=True, text=True)


def main():
    source = ROOT / 'build/QuotaBar.app'
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    stage = ROOT / 'build' / f'dmg-{version}'
    stage.mkdir(exist_ok=False)
    app = stage / 'Install QuotaBar.app'
    contents = app / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    resources = contents / 'Resources'
    resources.mkdir()
    run('ditto', source, resources / 'QuotaBar.app')
    run('ditto', ROOT / 'Localization', resources / 'Localization')
    run('cp', ROOT / 'QuotaBar.icns', resources / 'AppIcon.icns')
    installer_info = {
        'CFBundleIdentifier': 'dev.rebon.quotabar.installer', 'CFBundleName': 'Install QuotaBar',
        'CFBundleExecutable': 'InstallQuotaBar', 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': version, 'CFBundleVersion': info['CFBundleVersion'],
        'CFBundleIconFile': 'AppIcon', 'LSMinimumSystemVersion': info['LSMinimumSystemVersion'],
        'CFBundleDevelopmentRegion': 'en', 'CFBundleLocalizations': ['en', 'zh-Hans'],
        'NSHighResolutionCapable': True,
    }
    (contents / 'Info.plist').write_bytes(plistlib.dumps(installer_info))
    run('swiftc', '-O', '-parse-as-library', ROOT / 'Localization.swift',
        ROOT / 'installer/InstallerFiles.swift', ROOT / 'installer/App.swift',
        '-o', contents / 'MacOS/InstallQuotaBar')
    run('codesign', '--force', '--sign', '-', '--identifier', 'dev.rebon.quotabar.installer', app)
    run('codesign', '--verify', '--deep', '--strict', app)
    (stage / 'Read me - 安装说明.txt').write_text(
        '双击 Install QuotaBar，然后点「安装 QuotaBar」。安装后从菜单栏打开。\n'
        'Double-click Install QuotaBar, then click Install QuotaBar. Open it from the menu bar.\n\n'
        'Apple Silicon · macOS 27+\n'
        '此版本尚未经过 Apple 公证。如 macOS 阻止打开，请到「系统设置 → 隐私与安全性」中确认允许。\n'
        'This release is not notarized. If macOS blocks it, review it in System Settings → Privacy & Security.\n')
    output = ROOT / 'dist' / f'v{version}'
    output.mkdir(parents=True, exist_ok=True)
    dmg = output / 'QuotaBar-arm64.dmg'
    assert not dmg.exists(), 'Existing DMG preserved; use a new version or inspect the previous build.'
    run('hdiutil', 'create', '-volname', 'QuotaBar', '-srcfolder', stage,
        '-format', 'UDZO', '-ov', dmg)
    checksum = output / 'SHA256SUMS'
    with checksum.open('a') as handle:
        handle.write(f'{hashlib.sha256(dmg.read_bytes()).hexdigest()}  {dmg.name}\n')
    print(f'Verified installer and generated DMG: {dmg}')


if __name__ == '__main__':
    main()
