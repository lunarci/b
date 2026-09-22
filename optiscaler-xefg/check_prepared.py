"""Check build preparation gates; runtime regression tests live in tests/run.py."""
from pathlib import Path
import json
import sys
import xml.etree.ElementTree as ET
from prepare import KIT, NAME, NS, PIN, canonical, digest, git, safe_path


def check(source):
    source = source.resolve()
    evidence = json.loads((source / 'JAEYUN_PREPARED.json').read_text(encoding='utf-8'))
    if evidence['name'] != NAME or git(source, 'rev-parse', 'HEAD') != PIN:
        raise ValueError('Wrong prepared build identity.')
    if digest((KIT / 'jaeyun.patch').read_bytes()) != evidence['source']['patch_sha256']:
        raise ValueError('Patch changed after preparation.')
    if json.loads((KIT / 'SOURCE.json').read_text(encoding='utf-8')) != evidence['source']:
        raise ValueError('Source lock changed after preparation.')
    for name, sha in evidence['prepared_files'].items():
        if digest(canonical(safe_path(source, name).read_bytes())) != sha:
            raise ValueError(f'Prepared source changed: {name}')
    project = ET.parse(source / 'OptiScaler/OptiScaler.vcxproj')
    groups = [e for e in project.findall('m:ItemDefinitionGroup', NS)
              if e.get('Condition') == "'$(Configuration)|$(Platform)'=='Release|x64'"]
    if len(groups) != 1:
        raise ValueError('Release configuration missing.')
    group = groups[0]
    required = {'m:ClCompile/m:DebugInformationFormat': 'ProgramDatabase',
                'm:Link/m:GenerateDebugInformation': 'true',
                'm:Link/m:ProgramDatabaseFile': '$(OutDir)$(TargetName).pdb',
                'm:ClCompile/m:FloatingPointModel': 'Fast',
                'm:ClCompile/m:FavorSizeOrSpeed': 'Speed',
                'm:Link/m:OptimizeReferences': 'true',
                'm:Link/m:EnableCOMDATFolding': 'true'}
    for path, expected in required.items():
        if group.findtext(path, namespaces=NS) != expected:
            raise ValueError(f'Unexpected compiler/linker gate: {path}')
    if 'NDEBUG' not in group.findtext('m:ClCompile/m:PreprocessorDefinitions', namespaces=NS).split(';'):
        raise ValueError('Release assertions configuration changed.')
    resource = (source / 'OptiScaler/resource.h').read_text(encoding='utf-8')
    if resource.count(evidence['marker']) != 3:
        raise ValueError('Stable build suffix missing from version variants.')
    test_runner = KIT / 'tests/run.py'
    if not test_runner.is_file():
        raise ValueError('Required source regression test runner missing.')
    print('Source lock, prepared hashes, Release optimization and PDB gates verified.')
    return evidence


if __name__ == '__main__':
    check(Path(sys.argv[1]))
