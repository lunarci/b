"""Verify a genuine Windows build and assemble a settings-preserving MO2 overlay."""
from pathlib import Path
import hashlib
import json
import shutil
import struct
import subprocess
import sys
import zipfile

kit = Path(__file__).resolve().parent
source = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
release = source / 'x64/Release'
bundle = release / 'a'
dll = bundle / 'OptiScaler.dll'
if not dll.is_file():
    raise SystemExit('MSBuild did not produce the expected OptiScaler DLL.')
data = dll.read_bytes()
if data[:2] != b'MZ':
    raise SystemExit('Not a Windows PE image.')
pe = struct.unpack_from('<I', data, 0x3c)[0]
if data[pe:pe+4] != b'PE\0\0':
    raise SystemExit('Invalid PE signature.')
machine, sections, _, _, _, optsize, flags = struct.unpack_from('<HHIIIHH', data, pe+4)
if machine != 0x8664 or not flags & 0x2000 or struct.unpack_from('<H', data, pe+24)[0] != 0x20b:
    raise SystemExit('Expected a PE32+ AMD64 DLL.')
for export in (b'CreateDXGIFactory\0', b'CreateDXGIFactory1\0', b'CreateDXGIFactory2\0'):
    if export not in data:
        raise SystemExit(f'Missing expected DXGI proxy name: {export!r}')
if b'HUDResource-RC1' not in data and 'HUDResource-RC1'.encode('utf-16-le') not in data:
    raise SystemExit('The custom build marker is absent.')
required = ('amd_fidelityfx_loader_dx12.dll', 'amd_fidelityfx_upscaler_dx12.dll',
            'amd_fidelityfx_framegeneration_dx12.dll', 'amd_fidelityfx_vk.dll')
for name in required:
    if not (bundle / 'OptiScaler' / name).is_file():
        raise SystemExit(f'Matching upstream runtime missing: {name}')
stage = out / 'stage'
if stage.exists():
    raise SystemExit('Output stage already exists; use a clean build output.')
x64 = stage / 'Root/bin/x64'
x64.mkdir(parents=True)
shutil.copy2(dll, x64 / 'dxgi.dll')
shutil.copytree(bundle / 'OptiScaler', x64 / 'OptiScaler')
docs = stage / '_PackageDocs'
docs.mkdir()
for name in ('README_KO.md', 'SOURCE.json', 'REVIEW.md', 'hudless-current-frame.patch'):
    shutil.copy2(kit / name, docs / name)
shutil.copy2(source / 'LICENSE', docs / 'LICENSE_OptiScaler.txt')
if (bundle / 'Licenses').is_dir():
    shutil.copytree(bundle / 'Licenses', docs / 'Licenses')
legacy_license = source / 'external/FidelityFX-SDK/docs/license.md'
if legacy_license.is_file():
    (docs / 'Licenses').mkdir(exist_ok=True)
    shutil.copy2(legacy_license, docs / 'Licenses/FidelityFX_v1_LICENSE.md')
manifest = {
    'name': 'OptiScaler HUDResource RC1',
    'upstream': json.loads((kit / 'SOURCE.json').read_text()),
    'builder_commit': subprocess.check_output(['git', '-C', str(kit), 'rev-parse', 'HEAD'], text=True).strip(),
    'windows_msbuild_succeeded': True,
    'game_runtime_tested': False,
    'root_cause_confirmed': False,
    'scope': 'HUD selection/state correction; not a proven AMD driver crash or GPU residency fix',
    'settings': 'No OptiScaler.ini included; keep the existing v10 base mod and settings enabled',
    'files': {str(p.relative_to(stage)).replace('\\','/'): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(stage.rglob('*')) if p.is_file()},
}
(docs / 'BUILD.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
(out / 'BUILD.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
with zipfile.ZipFile(out / 'OptiScaler_HUDResource_RC1_MO2.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for p in sorted(stage.rglob('*')):
        if p.is_file(): z.write(p, p.relative_to(stage).as_posix())
# Keep the exact modified files and patch with the binary for audit/reproduction.
with zipfile.ZipFile(out / 'OptiScaler_HUDResource_RC1_Source.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for p in sorted(kit.rglob('*')):
        if p.is_file() and '__pycache__' not in p.parts: z.write(p, 'builder/' + p.relative_to(kit).as_posix())
    for rel in ('OptiScaler/framegen/ffx/FSRFG_Dx12.cpp', 'OptiScaler/resource.h', 'LICENSE'):
        z.write(source / rel, 'modified-source/' + rel)
    z.writestr('UPSTREAM.txt', json.dumps(manifest['upstream'], indent=2))
pdb = release / 'OptiScaler.pdb'
if pdb.is_file():
    with zipfile.ZipFile(out / 'OptiScaler_HUDResource_RC1_Symbols.zip', 'w', zipfile.ZIP_DEFLATED) as z:
        z.write(pdb, pdb.name)
for name in ('OptiScaler_HUDResource_RC1_MO2.zip', 'OptiScaler_HUDResource_RC1_Source.zip'):
    with zipfile.ZipFile(out / name) as z:
        if z.testzip() is not None: raise SystemExit('Invalid ZIP output.')
shutil.rmtree(stage)
print('Verified Windows x64 DLL and packaged MO2 overlay. No game-runtime validation claimed.')
