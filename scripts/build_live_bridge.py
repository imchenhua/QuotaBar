"""Build a metadata-only bridge; its signature never owns a credential item."""
from pathlib import Path
import hashlib, json, subprocess
root = Path(__file__).resolve().parents[1]
source = root/'CredentialAgent/LiveBridge.swift'
binary = root/'build/live-credential-bridge'
manifest = binary.with_suffix('.json')
digest = hashlib.sha256(source.read_bytes()).hexdigest()
previous = json.loads(manifest.read_text()) if manifest.exists() else {}
if not binary.exists() or previous.get('sourceSHA256') != digest:
    subprocess.run(['swiftc','-O','-suppress-warnings',str(source),'-o',str(binary)],check=True)
    subprocess.run(['codesign','--force','--sign','-','--identifier','dev.rebon.quotabar.live-credential-bridge',str(binary)],check=True)
binary_digest = hashlib.sha256(binary.read_bytes()).hexdigest()
manifest.write_text(json.dumps({'sourceSHA256':digest,'binarySHA256':binary_digest},indent=2))
identity = root/'build/AgentIdentity.swift'
text = '\n'.join(line for line in identity.read_text().splitlines() if not line.startswith('let liveCredentialBridgeSHA256'))
identity.write_text(text+'\n'+f'let liveCredentialBridgeSHA256 = "{binary_digest}"\n')
