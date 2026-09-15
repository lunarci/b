"""Package settings controls with the unchanged, previously built 0.2.4 payload."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

BASE_SHA = 'b69fee6abc8d0a81faa3e55d4f303edfb8e8a924bdc2621c4a51767e70028f53'
ASI_SHA = '8983dd9ff84b2615848ef3ac04f2e31fb150737f8867e26ced33cc8a8941e58d'
BASE_COMMIT = '70799157cc4307feedc1912d25f87e1c64b62eb8'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--base-zip', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--control-commit', required=True)
    parser.add_argument('--windows-run', required=True)
    args = parser.parse_args()
    assert len(args.control_commit) == 40 and all(c in '0123456789abcdef' for c in args.control_commit)
    assert args.windows_run.isdigit()
    assert hashlib.sha256(args.base_zip.read_bytes()).hexdigest() == BASE_SHA
    component = Path(__file__).resolve().parents[1]
    package = component / 'package'
    files = {}
    with zipfile.ZipFile(args.base_zip) as archive:
        for name in archive.namelist():
            relative = name.split('/', 1)[1]
            if relative in ('package-manifest.json', 'protected-files.json', 'LICENSE', 'NOTICE') or relative.startswith(('payload/', 'third_party/')):
                files[relative] = archive.read(name)
            elif relative in ('SOURCE.zip', 'BUILD_PROVENANCE.json'):
                files['baseline/' + relative] = archive.read(name)
    assert hashlib.sha256(files['payload/MatheusNR030.asi']).hexdigest() == ASI_SHA
    for name in ('Setup.ps1', 'Complete-Setup.ps1', 'Motion-Tuning.ps1', 'Skin-Control.ps1'):
        files[name] = (package / name).read_bytes()
    for name in ('Test-Complete-Package.ps1', 'Test-Motion-Tuning.ps1', 'Test-Skin-Control.ps1'):
        files['source/' + name] = (package / name).read_bytes()
    files['README_KO.md'] = (component / 'skin-control/README_KO.md').read_bytes()
    files['source/Build-Control-Package.py'] = Path(__file__).read_bytes()
    wrappers = {
        '01_APPLY_SKIN_CONTROL.cmd': ('Skin-Control.ps1', 'ApplySkin0'),
        '02_RESTORE_SKIN_CONTROL.cmd': ('Skin-Control.ps1', 'RestoreSkin'),
        '03_COLLECT_FULL_LOGS.cmd': ('Motion-Tuning.ps1', 'Collect'),
        'optional/SET_EFFECT_25.cmd': ('Motion-Tuning.ps1', 'Effect25'),
        'optional/SET_EFFECT_50.cmd': ('Motion-Tuning.ps1', 'Effect50'),
        'optional/SET_EFFECT_0.cmd': ('Motion-Tuning.ps1', 'Effect0'),
    }
    for path, (script, action) in wrappers.items():
        prefix = '%~dp0..\\' if path.startswith('optional/') else '%~dp0'
        text = ('@echo off\nsetlocal\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + prefix + script
                + '" -Action ' + action + '\nset "control_exit=%ERRORLEVEL%"\npause\nexit /b %control_exit%\n')
        files[path] = text.replace('\n', '\r\n').encode('ascii')
    # No user logs, videos, runtime caches, or untracked recovery code are inputs.
    provenance = {
        'name': 'Matheus_NR030_0.2.4_SkinControl',
        'type': 'configuration-only companion',
        'control_source_commit': args.control_commit,
        'control_source': 'https://github.com/lunarci/b/tree/' + args.control_commit,
        'windows_powershell_test_run': 'https://github.com/lunarci/b/actions/runs/' + args.windows_run,
        'adapter_rebuilt': False,
        'adapter_source_commit': BASE_COMMIT,
        'adapter_sha256': ASI_SHA,
        'base_package_sha256': BASE_SHA,
        'game_runtime_verified': False,
        'visual_improvement_verified': False,
        'files': {name: hashlib.sha256(content).hexdigest() for name, content in sorted(files.items())},
    }
    files['CONTROL_PROVENANCE.json'] = json.dumps(provenance, ensure_ascii=False, indent=2).encode('utf-8')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, content in sorted(files.items()):
            archive.writestr('Matheus_NR030_0.2.4_SkinControl/' + name, content)
    print(json.dumps({'file': str(args.output), 'size': args.output.stat().st_size,
                      'sha256': hashlib.sha256(args.output.read_bytes()).hexdigest()}))


if __name__ == '__main__':
    main()
