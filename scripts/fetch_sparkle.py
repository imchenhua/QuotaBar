"""Fetch the pinned official Sparkle distribution. No unpinned 'latest' dependencies."""
from pathlib import Path
import hashlib, shutil, tarfile, urllib.request

ROOT = Path(__file__).resolve().parents[1]
VERSION = '2.10.1'
DIGEST = '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27'
vendor = ROOT / 'vendor'
vendor.mkdir(exist_ok=True)
archive = vendor / f'Sparkle-{VERSION}.tar.xz'
if not archive.exists():
    pending = archive.with_suffix('.download')
    with urllib.request.urlopen(f'https://github.com/sparkle-project/Sparkle/releases/download/{VERSION}/{archive.name}', timeout=40) as source, pending.open('wb') as target:
        shutil.copyfileobj(source, target)
    if hashlib.sha256(pending.read_bytes()).hexdigest() != DIGEST:
        pending.unlink()
        raise SystemExit('Sparkle download checksum mismatch')
    pending.rename(archive)
assert hashlib.sha256(archive.read_bytes()).hexdigest() == DIGEST, 'Sparkle distribution checksum mismatch'
destination = vendor / f'Sparkle-{VERSION}'
if not (destination / 'Sparkle.framework').exists():
    destination.mkdir(exist_ok=True)
    with tarfile.open(archive) as bundle:
        for member in bundle.getmembers():
            path = (destination / member.name).resolve()
            assert path.is_relative_to(destination.resolve()), 'Unsafe archive path'
            if member.issym():
                assert (path.parent / member.linkname).resolve().is_relative_to(destination.resolve()), 'Unsafe symlink'
        bundle.extractall(destination)
print(f'Sparkle {VERSION}: verified')
