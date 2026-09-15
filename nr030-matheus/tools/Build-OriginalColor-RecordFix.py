"""Fix installer compatibility while preserving the exact tested diagnostic ASI."""
import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import zipfile

BASE_ZIP_SHA = '406f3b9162cd7f197686333bb6c31935025980f4eacd4377343597e133459049'
ASI_SHA = '41953c54e46417a88670a9e91b96a8e87198c2fa66174bdf6d810d834b175d75'
RUNTIME_COMMIT = 'a2cd9c849b4d07ea9671b0a5f03ebb3f7aa6995b'
NAME = 'Matheus_NR030_OriginalColor_AutoSetup'
REQUIRED = {
    'missing-record-adopts-verified-files-and-restores-absence-primary-and-overwrite',
    'missing-record-write-failures-preserve-absence-and-rollback-active-trial',
    'malformed-conflicting-or-directory-state-is-never-adopted',
    'missing-record-concurrent-state-creation-is-never-overwritten',
    'legacy-trial-without-original-state-flag-restores-existing-record',
    'effect-positive-values-and-missing-state-restore-independent-originals',
    'effect-missing-or-empty-key-restores-original-presence',
    'effect-restore-preserves-later-unrelated-ini-edits',
    'effect-ini-and-state-write-failures-rollback-whole-transaction',
    'effect-duplicate-key-stops-before-any-write',
    'effect-native-windows-parser-reads-zero-across-encodings',
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--base-zip', type=Path, required=True)
    parser.add_argument('--source-root', type=Path, required=True)
    parser.add_argument('--control-source-commit', required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    source = args.source_root.resolve(strict=True)
    spec = importlib.util.spec_from_file_location('base_builder', source / 'tools/Build-OriginalColor-Package.py')
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    require, digest, parse, encode = helper.require, helper.digest, helper.parse_json, helper.json_bytes
    require(re.fullmatch('[0-9a-f]{40}', args.control_source_commit), 'Fixed control source SHA required')
    require(re.fullmatch('[0-9]+', args.run_id), 'Fixed Windows test run required')
    require(not args.output.exists(), 'Refusing to replace an existing output')
    base_bytes = args.base_zip.read_bytes()
    require(digest(base_bytes) == BASE_ZIP_SHA, 'Wrong previous diagnostic package')
    files = helper.unroot(helper.archive_files(base_bytes))
    old_proof = files['BUILD_PROVENANCE.json']
    proof = parse(old_proof)
    for path, expected in proof['files'].items():
        require(digest(files[path]) == expected, 'Previous package hash mismatch: ' + path)
    require(digest(files['payload/MatheusNR030.asi']) == ASI_SHA, 'Wrong diagnostic ASI')
    require(proof['source_commit'] == RUNTIME_COMMIT, 'Wrong runtime source')
    helper.verify_handoff(files['evidence/handoff_results.json'], files['evidence/ctest-results.xml'])
    report_bytes = (source / 'package/test-results/original-color-control-tests.json').read_bytes()
    report = helper.verify_control(report_bytes)
    require(REQUIRED.issubset({t['Name'] for t in report['Tests']}) and report['Passed'] >= 20
            and report.get('NativeEffectApiVerified') is True,
            'Automatic Effect-zero Windows/native-INI regression evidence is incomplete')
    for name in ('Setup.ps1', 'Complete-Setup.ps1', 'Motion-Tuning.ps1'):
        require((source / 'package' / name).read_bytes() == files[name], 'Unexpected helper change: ' + name)
    files['Original-Color-Control.ps1'] = (source / 'package/Original-Color-Control.ps1').read_bytes()
    files['README_KO.md'] = (source / 'original-color-test/README_KO.md').read_bytes()
    files['evidence/prior-original-color-control-tests.json'] = files['evidence/original-color-control-tests.json']
    files['evidence/original-color-control-tests.json'] = report_bytes
    files['evidence/package-tests/original-color-control-tests.json'] = report_bytes
    files['evidence/prior-BUILD_PROVENANCE.json'] = old_proof
    manifest = parse(files['package-manifest.json'])
    # Keep the ASI's actual original build/source provenance. Installer revision
    # has its own source/run fields, so it cannot masquerade as a rebuilt ASI.
    manifest['addon_version'] = '0.2.4-original-color-trial-autoeffect1'
    manifest['control_source_commit'] = args.control_source_commit
    manifest['control_test_run_id'] = args.run_id
    files['package-manifest.json'] = encode(manifest)
    installer_source = io.BytesIO()
    with zipfile.ZipFile(installer_source, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in ('package/Original-Color-Control.ps1', 'package/Test-Original-Color-Control.ps1',
                     'tools/Build-OriginalColor-RecordFix.py', 'original-color-test/README_KO.md'):
            archive.writestr('nr030-matheus/' + path, (source / path).read_bytes())
        workflow = '.github/workflows/test-nr030-original-color-record.yml'
        archive.writestr(workflow, (source.parent / workflow).read_bytes())
    files['INSTALLER_SOURCE.zip'] = installer_source.getvalue()
    proof.update(name=NAME, adapter_rebuilt=False, adapter_sha256=ASI_SHA,
                 control_revision='autoeffect1', control_source_commit=args.control_source_commit,
                 control_source='https://github.com/lunarci/b/tree/' + args.control_source_commit,
                 control_test_run_id=args.run_id,
                 control_test_workflow='https://github.com/lunarci/b/actions/runs/' + args.run_id,
                 windows_powershell51_control_cases=report['Passed'],
                 native_windows_effect_read_verified=True,
                 missing_installation_record_supported=True,
                 original_record_absence_restored=True,
                 required_existing_effect_percent=None,
                 trial_effect_percent=0,
                 prepares_effect_zero_automatically=True,
                 restores_original_effect_setting=True,
                 ini_files_installed_or_modified=True,
                 ini_change_scope='Existing MatheusNR030.ini EffectPercent only; native-compatible encoding when rewriting; all other setting values preserved',
                 restore='Original ASI and record presence/bytes; restore pre-trial Effect while preserving later unrelated INI edits',
                 previous_package_sha256=BASE_ZIP_SHA,
                 source_archive_note='SOURCE.zip is the exact compiled ASI source; INSTALLER_SOURCE.zip contains this installer revision')
    files.pop('BUILD_PROVENANCE.json')
    proof['files'] = {p: digest(b) for p, b in sorted(files.items())}
    files['BUILD_PROVENANCE.json'] = encode(proof)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, 'x', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path, data in sorted(files.items()):
            archive.writestr(NAME + '/' + path, data)
    print(json.dumps({'file': str(args.output), 'sha256': digest(args.output.read_bytes()),
                      'asi_sha256': ASI_SHA, 'control_tests': report['Passed']}))


if __name__ == '__main__':
    main()
