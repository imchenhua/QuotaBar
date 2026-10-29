from pathlib import Path
import hashlib, json, subprocess, shutil
root=Path(__file__).resolve().parents[1]
source=root/'CredentialAgent/main.swift'
agent=root/'build/credential-agent-v1'
manifest=root/'build/credential-agent-v1.json'
source_hash=hashlib.sha256(source.read_bytes()).hexdigest()
if agent.exists():
    data=json.loads(manifest.read_text())
    if data['sourceSHA256'] != source_hash or data['binarySHA256'] != hashlib.sha256(agent.read_bytes()).hexdigest():
        raise SystemExit('CredentialAgent differs from pinned v1. Review and version the agent explicitly; no automatic replacement.')
else:
    installed = Path.home()/'.local/libexec/quotabar/credential-agent-v1'
    if installed.exists():
        installed_manifest = json.loads(installed.with_suffix('.json').read_text())
        if installed_manifest['sourceSHA256'] != source_hash or installed_manifest['binarySHA256'] != hashlib.sha256(installed.read_bytes()).hexdigest():
            raise SystemExit('Installed credential identity mismatch; refusing to rebuild or replace it.')
        shutil.copy2(installed, agent)
        manifest.write_text(json.dumps(installed_manifest, indent=2))
    elif (root/'support/credential-agent-v1').exists():
        pinned=root/'support/credential-agent-v1'
        pinned_manifest=json.loads((root/'support/credential-agent-v1.json').read_text())
        if pinned_manifest['sourceSHA256']!=source_hash or pinned_manifest['binarySHA256']!=hashlib.sha256(pinned.read_bytes()).hexdigest():
            raise SystemExit('Repository credential identity mismatch; refusing to rebuild or replace it.')
        shutil.copy2(pinned,agent)
    else:
        subprocess.run(['swiftc','-O',str(source),'-o',str(agent)],check=True)
        subprocess.run(['codesign','--sign','-','--identifier','dev.rebon.quotabar.credential-agent.v1',str(agent)],check=True)
    manifest.write_text(json.dumps({'sourceSHA256':source_hash,'binarySHA256':hashlib.sha256(agent.read_bytes()).hexdigest()},indent=2))
digest=hashlib.sha256(agent.read_bytes()).hexdigest()
identity=root/'build/AgentIdentity.swift'
generated=f'let credentialAgentSHA256 = "{digest}"\n'
if not identity.exists() or identity.read_text()!=generated:
    identity.write_text(generated)
