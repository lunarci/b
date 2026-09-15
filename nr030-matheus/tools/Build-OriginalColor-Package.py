"""Package the CI-built Effect-0 original-color handoff comparison, with strict gates."""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import struct
import xml.etree.ElementTree as ET
import zipfile

NAME = "Matheus_NR030_OriginalColor_Test"
BASELINE_SHA = "8983dd9ff84b2615848ef3ac04f2e31fb150737f8867e26ced33cc8a8941e58d"
NR_SHA = "c7aad08f555bb8a7650f084c3e35aa188587060754ba0ac6538a5152c0a9f2de"
PAYLOADS = ("MatheusNR030.asi", "MatheusNR030.ini")
SCRIPTS = ("Setup.ps1", "Complete-Setup.ps1", "Motion-Tuning.ps1", "Original-Color-Control.ps1")
REQUIRED_CONTROL_CASES = {
    "apply-restores-exact-asi-and-state-preserving-all-inis-and-xefg-five-times",
    "missing-overwrite-remains-absent-and-reapply-preserves-first-backup",
    "restore-preserves-later-user-ini-edits-and-does-not-require-payload",
    "wrong-settings-base-hash-unowned-or-modified-addon-block-before-writes",
    "tampered-backups-trial-state-or-binaries-block-restore",
    "apply-and-restore-failures-rollback-each-write-including-second-asi",
    "pre-first-write-conflict-never-rolls-back-over-external-edit",
    "staged-source-tamper-blocks-apply-and-rolls-back-partial-restore",
    "running-game-and-corrupt-payload-block-and-status-is-read-only",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(content):
    return hashlib.sha256(content).hexdigest()


def parse_json(content):
    return json.loads(content.decode("utf-8-sig"))


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def archive_files(content):
    result = {}
    with zipfile.ZipFile(io.BytesIO(content)) as archive:
        for entry in archive.infolist():
            name = entry.filename.replace("\\", "/")
            path = PurePosixPath(name)
            require(not path.is_absolute() and ".." not in path.parts and ":" not in name,
                    "Unsafe ZIP path: " + name)
            if entry.is_dir() or name.endswith("/"):
                continue
            require(str(path) == name and name not in result, "Duplicate or ambiguous ZIP entry: " + name)
            require(entry.file_size <= 256 * 1024 * 1024, "Oversized ZIP entry: " + name)
            result[name] = archive.read(entry)
    return result


def unroot(files):
    roots = {name.split("/", 1)[0] for name in files}
    require(len(roots) == 1 and all("/" in name for name in files), "Expected one package root")
    return {name.split("/", 1)[1]: content for name, content in files.items()}


def verify_control(content):
    report = parse_json(content)
    cases = report.get("Tests", [])
    require(report.get("Component") == "OriginalColorControl" and report.get("SchemaVersion") == 1,
            "Wrong original-color control evidence schema")
    require(report.get("NativeWindows") is True and report.get("WindowsPowerShell51") is True and
            str(report.get("PowerShellVersion", "")).startswith("5.1."),
            "Native Windows PowerShell 5.1 control execution is required")
    require(report.get("Failed") == 0 and report.get("Passed", 0) >= 9 and
            report.get("TestCount") == report.get("Passed") == len(cases) and
            report.get("GameplayVisualQualityVerified") is False,
            "Original-color control tests failed or claim unsupported gameplay verification")
    names = [case.get("Name") for case in cases]
    require(len(set(names)) == len(names) and REQUIRED_CONTROL_CASES.issubset(names) and
            all(case.get("Status") == "PASS" for case in cases),
            "Required original-color control regression cases did not pass")
    return report


def verify_handoff(content, ctest_content):
    report = parse_json(content)
    require(report.get("success") is True and report.get("passedCount") == 3 and
            report.get("amdGpuGameTested") is False,
            "All three production After() handoff tests must pass without a gameplay claim")
    suite = ET.fromstring(ctest_content)
    require(suite.tag == "testsuite" and all(int(suite.get(key, "0")) == 0
            for key in ("failures", "errors", "skipped", "disabled")),
            "Native CTest suite has failures, errors, skipped or disabled cases")
    matches = [case for case in suite.findall("testcase") if case.get("name") == "nr030_handoff_checks"]
    require(len(matches) == 1 and matches[0].get("status") == "run" and
            all(matches[0].find(tag) is None for tag in ("failure", "error", "skipped")),
            "The native CTest handoff executable did not run successfully")
    return report


def wrapper(script, action):
    # A quoted optional first argument overrides the standard MO2 root. The ZIP
    # itself can be extracted anywhere; helpers resolve through this CMD's path.
    command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0' + script + '" -Action ' + action
    text = ('@echo off\nsetlocal DisableDelayedExpansion\n'
            'if "%~1"=="" (\n  ' + command + '\n) else (\n  ' + command + ' -Mo2Root "%~1"\n)\n'
            'set "trial_exit=%ERRORLEVEL%"\npause\nexit /b %trial_exit%\n')
    return text.replace("\n", "\r\n").encode("ascii")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-zip", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--handoff-results", type=Path, required=True)
    parser.add_argument("--control-results", type=Path, required=True)
    args = parser.parse_args()
    require(re.fullmatch(r"[0-9a-f]{40}", args.source_commit), "A fixed lowercase source SHA is required")
    require(re.fullmatch(r"[0-9]+", args.run_id), "A numeric CI run ID is required")
    require(not args.output.exists(), "Refusing to overwrite an existing output ZIP")
    source_root = args.source_root.resolve(strict=True)
    base_bytes = args.base_zip.read_bytes()
    base = unroot(archive_files(base_bytes))
    manifest_bytes = base["package-manifest.json"]
    manifest = parse_json(manifest_bytes)
    run_url = "https://github.com/lunarci/b/actions/runs/" + args.run_id
    require(manifest.get("schema_version") == 1 and manifest.get("addon_name") == "MatheusNR030" and
            manifest.get("base_nr_sha256") == NR_SHA and manifest.get("source_commit") == args.source_commit and
            str(manifest.get("build_run_id")) == args.run_id and manifest.get("build_evidence") == run_url and
            manifest.get("runtime_log_schema") == "matheusnr030-events-v1" and
            manifest.get("build_verified") is True and manifest.get("abi_verified") is True and
            manifest.get("game_runtime_verified") is False and bool(manifest.get("abi_evidence")),
            "CI package manifest/provenance gate failed")
    ci_provenance = parse_json(base["BUILD_PROVENANCE.json"])
    require(ci_provenance.get("source_commit") == args.source_commit and
            str(ci_provenance.get("build_run_id")) == args.run_id and
            ci_provenance.get("runtime_enabled_at_build") is True and
            ci_provenance.get("amd_gpu_game_tested") is False,
            "CI build provenance does not match the requested source/run")
    entries = manifest.get("files", [])
    require(len(entries) == 2 and {entry.get("name") for entry in entries} == set(PAYLOADS),
            "Exactly the two declared add-on payload files are required")
    for entry in entries:
        content = base["payload/" + entry["name"]]
        require(entry.get("sha256") == digest(content) and entry.get("size") == len(content),
                "Payload size/SHA-256 mismatch: " + entry["name"])
    asi = base["payload/MatheusNR030.asi"]
    require(len(asi) >= 64 and asi[:2] == b"MZ", "ASI is not a PE image")
    pe = struct.unpack_from("<I", asi, 60)[0]
    require(pe <= len(asi) - 24 and asi[pe:pe + 4] == b"PE\0\0" and
            struct.unpack_from("<H", asi, pe + 4)[0] == 0x8664 and
            struct.unpack_from("<H", asi, pe + 22)[0] & 0x2000,
            "Expected a Windows x64 DLL payload")
    require(digest(asi) != BASELINE_SHA and args.source_commit.encode("ascii") in asi,
            "Expected a rebuilt diagnostic ASI embedding the requested source commit")
    for marker in (b"event=effect_zero_handoff", b"event=original_color_stats passthrough=",
                   b"original_color_passthrough"):
        require(marker in asi, "The rebuilt ASI lacks the diagnostic handoff marker")

    handoff_bytes = args.handoff_results.read_bytes()
    control_bytes = args.control_results.read_bytes()
    handoff = verify_handoff(handoff_bytes, base["evidence/ctest-results.xml"])
    controls = verify_control(control_bytes)
    require(base.get("evidence/package-tests/original-color-control-tests.json") == control_bytes,
            "Control evidence differs from the evidence bundled by the CI source build")
    compiled_source = archive_files(base["SOURCE.zip"])
    for name in ("addon/MatheusNR030.cpp", "addon/handoff_checks.cpp", "addon/lifetime.cpp",
                 "addon/CMakeLists.txt", "gpu_tests/shader_executor.cpp", "runtime_contract.h",
                 "package/Test-Original-Color-Control.ps1"):
        require("nr030-matheus/" + name in compiled_source, "Compiled source/test missing from SOURCE.zip: " + name)

    files = {}
    for name, content in base.items():
        if (name in ("SOURCE.zip", "protected-files.json", "LICENSE", "NOTICE") or
                name in {"payload/" + item for item in PAYLOADS} or
                name.startswith(("third_party/", "evidence/"))):
            files[name] = content
    for name in SCRIPTS:
        relative = "package/" + name
        content = (source_root / relative).read_bytes()
        require(compiled_source.get("nr030-matheus/" + relative) == content,
                "Local control script differs from the compiled source archive: " + name)
        files[name] = content
    for relative in ("original-color-test/README_KO.md", "tools/Build-OriginalColor-Package.py"):
        content = (source_root / relative).read_bytes()
        require(compiled_source.get("nr030-matheus/" + relative) == content,
                "Diagnostic packaging source differs from the compiled source archive: " + relative)
        if relative.endswith("README_KO.md"):
            files["README_KO.md"] = content
    files["evidence/CI-package-manifest.json"] = manifest_bytes
    files["evidence/CI-BUILD_PROVENANCE.json"] = base["BUILD_PROVENANCE.json"]
    files["evidence/handoff_results.json"] = handoff_bytes
    files["evidence/original-color-control-tests.json"] = control_bytes
    # Only the descriptive version changes. CI hashes, source/run IDs and ABI
    # evidence stay intact, and the original manifest is retained for comparison.
    manifest["addon_version"] = "0.2.4-original-color-trial"
    files["package-manifest.json"] = json_bytes(manifest)
    for filename, script, action in (
        ("01_APPLY_ORIGINAL_COLOR_TEST.cmd", "Original-Color-Control.ps1", "Apply"),
        ("02_RESTORE_PREVIOUS_ADDON.cmd", "Original-Color-Control.ps1", "Restore"),
        ("03_COLLECT_LOGS.cmd", "Motion-Tuning.ps1", "Collect"),
    ):
        files[filename] = wrapper(script, action)
    provenance = {
        "name": NAME,
        "purpose": "Effect-0 original-color resource handoff comparison; not a verified graphics fix",
        "source_commit": args.source_commit,
        "source": "https://github.com/lunarci/b/tree/" + args.source_commit + "/nr030-matheus",
        "build_run_id": args.run_id,
        "workflow": run_url,
        "ci_base_package_sha256": digest(base_bytes),
        "baseline_adapter_sha256": BASELINE_SHA,
        "adapter_sha256": digest(asi),
        "adapter_rebuilt": True,
        "nr_calculation_unchanged": True,
        "required_existing_scale_percent": 85,
        "required_existing_effect_percent": 0,
        "effect_zero_handoff": "Original FFX color resource; resolve shader and replacement omitted",
        "positive_effect_path_changed": False,
        "xefg_configuration_changed": False,
        "upscaler_configuration_changed": False,
        "ini_files_installed_or_modified": False,
        "payload_ini_role": "CI payload hash validation only; installer never copies this INI",
        "nr_or_model_downloaded_or_replaced": False,
        "windows_powershell51_control_cases": controls["Passed"],
        "native_handoff_cases": handoff["passedCount"],
        "restore": "Exact previous add-on ASI and ownership state; preserve all current INIs",
        "user_reported_latency_improvement": "Existing configuration improved from 40 to 20; this build is unmeasured",
        "game_runtime_verified": False,
        "visual_improvement_verified": False,
        "latency_improvement_verified": False,
        "files": {name: digest(content) for name, content in sorted(files.items())},
    }
    files["BUILD_PROVENANCE.json"] = json_bytes(provenance)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, "x", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, content in sorted(files.items()):
            archive.writestr(NAME + "/" + name, content)
    print(json.dumps({"file": str(args.output), "size": args.output.stat().st_size,
                      "sha256": digest(args.output.read_bytes()), "source_commit": args.source_commit}))


if __name__ == "__main__":
    main()
