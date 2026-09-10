"""Package reviewed deployment tools with an immutable, previously compiled DLL.

No compiler substitution: the original Actions ZIP and the DLL are SHA256 pinned.
"""
from pathlib import Path, PurePosixPath
import hashlib
import io
import json
import os
import subprocess
import sys
import urllib.request
import zipfile

ARTIFACT_ID = 10134497233
ARTIFACT_SHA = '0f8bb845bd968418b6d1658cb152500673998909b3407027bbecd043330a19eb'
DLL_SHA = '31d2d2b9149ecf169b62bc48be58ccae75e3497f1e869de80193c293db3e3020'
kit = Path(__file__).resolve().parent


def sha(data):
    return hashlib.sha256(data).hexdigest()


def safe_members(archive):
    names = archive.namelist()
    if len(names) != len(set(names)):
        raise ValueError('Duplicate ZIP entry.')
    for name in names:
        p = PurePosixPath(name)
        if p.is_absolute() or '..' in p.parts or '\\' in name or ':' in name:
            raise ValueError('Unsafe ZIP entry.')
    if archive.testzip() is not None:
        raise ValueError('Invalid ZIP CRC.')
    return names


if len(sys.argv) != 3:
    raise SystemExit('Usage: assemble.py <original-Actions-ZIP|--download> <output-directory>')
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
if sys.argv[1] == '--download':
    # Prevent sending the GitHub API credential to the redirected blob host.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    api = f'https://api.github.com/repos/lunarci/b/actions/artifacts/{ARTIFACT_ID}/zip'
    request = urllib.request.Request(api, headers={
        'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
        'User-Agent': 'OptiScaler-HUDResource-package-builder',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
    })
    try:
        response = urllib.request.build_opener(NoRedirect).open(request, timeout=60)
    except urllib.error.HTTPError as error:
        if error.code not in (301, 302, 303, 307, 308):
            raise RuntimeError(f'Artifact API failed with HTTP {error.code}') from None
        location = error.headers['Location']
        if not location.startswith('https://'):
            raise RuntimeError('Artifact redirect was not HTTPS.')
        response = urllib.request.urlopen(location, timeout=90)
    with response:
        original = response.read()
else:
    original = Path(sys.argv[1]).read_bytes()
if sha(original) != ARTIFACT_SHA:
    raise SystemExit('Original Windows Actions artifact hash mismatch.')

with zipfile.ZipFile(io.BytesIO(original)) as outer:
    safe_members(outer)
    payload_zip = outer.read('OptiScaler_HUDResource_RC1_MO2.zip')
    source_zip = outer.read('OptiScaler_HUDResource_RC1_Source.zip')

with zipfile.ZipFile(io.BytesIO(payload_zip)) as payload:
    names = safe_members(payload)
    build = json.loads(payload.read('_PackageDocs/BUILD.json'))
    for name, expected in build['files'].items():
        if sha(payload.read(name)) != expected:
            raise ValueError(f'Original manifest mismatch: {name}')
    data = {name: payload.read(name) for name in names if not name.endswith('/')}
if sha(data['Root/bin/x64/dxgi.dll']) != DLL_SHA:
    raise SystemExit('Compiled DLL hash mismatch.')
required = ['amd_fidelityfx_loader_dx12.dll', 'amd_fidelityfx_upscaler_dx12.dll',
            'amd_fidelityfx_framegeneration_dx12.dll', 'amd_fidelityfx_vk.dll',
            'libxess.dll', 'libxess_dx11.dll', 'libxess_fg.dll', 'libxell.dll',
            'D3D12_OptiScaler/D3D12Core.dll']
for name in required:
    if 'Root/bin/x64/OptiScaler/' + name not in data:
        raise ValueError(f'Runtime missing: {name}')
for name in ['Manage-OptiScalerOverwrite.ps1', 'Apply-Overwrite-Fix.cmd',
             'Check-Overwrite.cmd', 'Restore-Overwrite.cmd', 'README_KO.md']:
    content = (kit / name).read_bytes()
    if name.endswith('.cmd'):
        # Batch launchers must also work when the Git checkout used LF endings.
        content = content.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
    data['tools/' + name] = content
data['START_HERE_KO.md'] = (kit / 'START_HERE_KO.md').read_bytes()
data['_PackageDocs/DLL_PE_VERIFICATION.json'] = (kit / 'DLL_PE_VERIFICATION.json').read_bytes()
revision = os.environ.get('GITHUB_SHA')
if not revision:
    revision = subprocess.check_output(['git', '-C', str(kit), 'rev-parse', 'HEAD'], text=True).strip()
build['deployment_commit'] = revision
build['deployment_revision'] = 2
build['original_windows_run'] = 'https://github.com/lunarci/b/actions/runs/34430740861'
build['deployment_verification_run'] = (
    'https://github.com/lunarci/b/actions/runs/' + os.environ.get('GITHUB_RUN_ID', 'local'))
build['powershell_5_1_tests'] = 'See deployment verification run; not a game-runtime test'
build['files'] = {name: sha(content) for name, content in sorted(data.items()) if name != '_PackageDocs/BUILD.json'}
data['_PackageDocs/BUILD.json'] = json.dumps(build, indent=2).encode()
with zipfile.ZipFile(out / 'OptiScaler_HUDResource_RC1_MO2.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for name, content in sorted(data.items()):
        archive.writestr(name, content)
with zipfile.ZipFile(out / 'OptiScaler_HUDResource_RC1_Source.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    with zipfile.ZipFile(io.BytesIO(source_zip)) as source:
        for name in safe_members(source):
            archive.writestr(name, source.read(name))
    for p in sorted(kit.iterdir()):
        if p.is_file():
            archive.write(p, 'deployment-tools/' + p.name)
    archive.write(kit.parent / '.github/workflows/verify-optiscaler-deployment.yml',
                  'deployment-tools/verify-optiscaler-deployment.yml')
(out / 'verified-dxgi.dll').write_bytes(data['Root/bin/x64/dxgi.dll'])
(out / 'BUILD.json').write_text(json.dumps(build, indent=2), encoding='utf-8')
print('Verified immutable DLL and all runtime hashes; packaged deployment tools without changing settings.')
