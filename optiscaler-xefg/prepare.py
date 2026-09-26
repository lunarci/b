"""Apply an exactly locked source patch and enable optimized Release symbols."""
from pathlib import Path, PurePosixPath
import hashlib
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
import xml.etree.ElementTree as ET

PIN = '9eea95bba9fda7121f214d2eba358423be598d7e'
REPOSITORY = 'https://github.com/Coldwood1026/OptiScalerDp4aUnlock'
NAME = 'JaeYun-XeFG6x-r5'
KIT = Path(__file__).resolve().parent
NS = {'m': 'http://schemas.microsoft.com/developer/msbuild/2003'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(data):
    return data.replace(b'\r\n', b'\n')


def git(source, *args):
    return subprocess.check_output(['git', '-C', str(source), *args], text=True).strip()


def safe_path(source, name):
    p = PurePosixPath(name)
    if p.is_absolute() or '..' in p.parts or '\\' in name or not p.parts:
        raise ValueError(f'Invalid locked path: {name}')
    if p.parts[0] == '.git':
        raise ValueError('Git metadata cannot be patched.')
    target = source.joinpath(*p.parts)
    if source not in target.resolve().parents:
        raise ValueError(f'Locked path escapes source: {name}')
    return target


def check_hash(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) is not None


def release_symbols(text):
    # Preserve project formatting/BOM and alter only Release|x64 item settings.
    pat = r'(<ItemDefinitionGroup Condition="\'\$\(Configuration\)\|\$\(Platform\)\'==\'Release\|x64\'">)(.*?)(</ItemDefinitionGroup>)'
    matches = list(re.finditer(pat, text, re.S))
    if len(matches) != 1:
        raise ValueError('Expected one Release|x64 item settings group.')
    match = matches[0]
    block = match.group(2)
    if '<PreprocessorDefinitions>NDEBUG;' not in block:
        raise ValueError('Release NDEBUG configuration changed.')
    old = '<GenerateDebugInformation>false</GenerateDebugInformation>'
    if block.count(old) != 1:
        raise ValueError('Unexpected Release linker symbols setting.')
    block = block.replace(old, '<GenerateDebugInformation>true</GenerateDebugInformation>\n      <ProgramDatabaseFile>$(OutDir)$(TargetName).pdb</ProgramDatabaseFile>')
    if '<DebugInformationFormat>' in block:
        raise ValueError('Unexpected existing Release compiler debug format.')
    block = block.replace('<ClCompile>', '<ClCompile>\n      <DebugInformationFormat>ProgramDatabase</DebugInformationFormat>', 1)
    result = text[:match.start(2)] + block + text[match.end(2):]
    ET.fromstring(result.lstrip('\ufeff'))
    return result


def prepare(source):
    source = source.resolve()
    spec = json.loads((KIT / 'SOURCE.json').read_text(encoding='utf-8'))
    if spec.get('commit') != PIN or spec.get('repository', '').rstrip('/') != REPOSITORY:
        raise ValueError('Source lock does not name the audited donor.')
    if git(source, 'rev-parse', 'HEAD') != PIN:
        raise ValueError('Unexpected source HEAD.')
    if git(source, 'status', '--porcelain', '--untracked-files=all'):
        raise ValueError('Source checkout must be pristine.')
    patch = KIT / 'jaeyun.patch'
    if not check_hash(spec.get('patch_sha256')) or digest(patch.read_bytes()) != spec['patch_sha256']:
        raise ValueError('Patch SHA-256 mismatch or unpopulated source lock.')
    locked = spec.get('files')
    if not isinstance(locked, dict) or not locked:
        raise ValueError('No locked source paths.')
    patched_names = []
    for line in git(source, 'apply', '--numstat', str(patch)).splitlines():
        _, _, name = line.split('\t', 2)
        patched_names.append(name)
    if len(patched_names) != len(set(patched_names)) or set(patched_names) != set(locked):
        raise ValueError('Patch paths and source lock disagree.')
    for name, hashes in locked.items():
        target = safe_path(source, name)
        before = hashes.get('before_sha256')
        after = hashes.get('after_sha256')
        if not check_hash(after) or (before is not None and not check_hash(before)):
            raise ValueError(f'Invalid source hashes: {name}')
        if before is None:
            if target.exists():
                raise ValueError(f'New source already exists: {name}')
        else:
            data = canonical(target.read_bytes())
            if digest(data) != before:
                raise ValueError(f'Original source hash mismatch: {name}')
            target.write_bytes(data)
    subprocess.run(['git', '-C', str(source), 'apply', '--check', str(patch)], check=True)
    subprocess.run(['git', '-C', str(source), 'apply', str(patch)], check=True)
    for name, hashes in locked.items():
        target = safe_path(source, name)
        data = canonical(target.read_bytes())
        if digest(data) != hashes['after_sha256']:
            raise ValueError(f'Patched source hash mismatch: {name}')
        target.write_bytes(data)

    builder_commit = git(KIT, 'rev-parse', 'HEAD')
    if not re.fullmatch(r'[0-9a-f]{40}', builder_commit):
        raise ValueError('Builder commit unavailable.')
    marker = f'{NAME}-{builder_commit[:12]}'
    resource = source / 'OptiScaler/resource.h'
    text = resource.read_text(encoding='utf-8')
    pattern = r'(#define VER_PRODUCT_VERSION_STR[^\n]*\\\n[^\n]*)(\n)'
    text, count = re.subn(pattern, lambda m: m[1] + f' " [{marker}]"' + m[2], text)
    if count != 3:
        raise ValueError('Unexpected version macro layout.')
    resource.write_text(text, encoding='utf-8', newline='\n')
    project = source / 'OptiScaler/OptiScaler.vcxproj'
    project.write_text(release_symbols(project.read_text(encoding='utf-8')), encoding='utf-8', newline='\n')

    instrumented = sorted(set(locked) | {'OptiScaler/resource.h', 'OptiScaler/OptiScaler.vcxproj'})
    evidence = {
        'schema_version': 1,
        'name': NAME,
        'marker': marker,
        'source': spec,
        'builder_commit': builder_commit,
        'prepared_utc': datetime.now(timezone.utc).isoformat(),
        'instrumentation': 'Release PDB enabled; optimization and NDEBUG preserved; resource version suffix added.',
        'prepared_files': {n: digest(canonical(safe_path(source, n).read_bytes())) for n in instrumented},
        'submodules': git(source, 'submodule', 'status', '--recursive').splitlines(),
        'game_runtime_tested': False,
    }
    if any(line.startswith(('-', '+', 'U')) for line in evidence['submodules']):
        raise ValueError('Submodules must be initialized at their pinned revisions.')
    (source / 'JAEYUN_PREPARED.json').write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
    subprocess.run(['git', '-C', str(source), 'diff', '--check'], check=True)
    print(f'Prepared {marker}; exact patch and source hashes verified.')


if __name__ == '__main__':
    prepare(Path(sys.argv[1]))
