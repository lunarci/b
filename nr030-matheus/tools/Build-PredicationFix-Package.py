"""Assemble the predication-state repair from matching Windows CI evidence."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import struct
import xml.etree.ElementTree as ET
import zipfile

_spec = importlib.util.spec_from_file_location(
    "original_color_packaging", Path(__file__).with_name("Build-OriginalColor-Package.py"))
_base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_base)
require, digest, parse_json, json_bytes = _base.require, _base.digest, _base.parse_json, _base.json_bytes
archive_files, unroot = _base.archive_files, _base.unroot
NAME = "Matheus_NR030_PredicationFix"
REQUIRED_PRESERVE_CASES = {
    "preserve-effect-current-values-and-known-binaries-without-state",
    "preserve-effect-upgrade-keeps-prior-effect-restore-chain",
    "preserve-effect-upgrade-without-effect-ownership-retains-later-values",
}
REQUIRED_PREDICATION_CASES = {
    "GPU EQUAL_ZERO conditional-copy control is broken without guard and preserved with guard",
    "GPU NOT_EQUAL_ZERO at nonzero offset preserves the actual conditional-copy result",
    "GPU active predicate that permits work still permits the original conditional copy",
    "GPU EQUAL_ZERO initially-passing snapshot survives source mutation and rejects unsafe rebind",
    "GPU NOT_EQUAL_ZERO initially-passing snapshot survives source mutation and rejects unsafe rebind",
    "GPU known-disabled scope clears private predicate before one original callback",
    "GPU known-disabled scope clears private predicate on exception before one fallback callback",
}
REQUIRED_SESSION_CASES = {
    "original-colour-recording-is-not-gpu-or-visual-proof",
    "source-mismatch-and-missing-source-do-not-pass",
    "stale-session-does-not-pass",
    "latest-empty-or-malformed-session-blocks-old-recording",
    "mode-config-and-counter-evidence-are-all-required",
    "mismatched-truncated-and-overflow-counters-do-not-pass",
    "ordinary-positive-effect-recording-still-works",
    "old-default-and-missing-configured-log-are-explicit",
    "timestamp-compatibility-does-not-prove-runtime",
    "missing-session-time-cannot-classify-log-as-current",
    "all-file-hashes-preserved-by-read-only-checks",
    "no-active-predicate-is-not-evidence-of-artifact-cause",
    "active-predicate-bypass-is-observation-not-fix-proof",
    "predication-evidence-requires-current-mode-source-and-valid-counters",
    "check-allows-preserved-four-five-times-without-relaxing-installer",
}


def verify_predication(content, ctest_content):
    report = parse_json(content)
    names = report.get("passed", [])
    require(report.get("success") is True and report.get("failure") == "" and
            report.get("amdGpuGameTested") is False and isinstance(names, list) and
            report.get("passedCount", 0) >= 14 and report.get("passedCount") == len(names) and
            all(isinstance(name, str) and name for name in names) and len(set(names)) == len(names) and
            REQUIRED_PREDICATION_CASES.issubset(names),
            "Native predication tests did not all pass, or claim unsupported game verification")
    suite = ET.fromstring(ctest_content)
    cases = [case for case in suite.findall("testcase") if case.get("name") == "nr030_predication_checks"]
    require(len(cases) == 1 and cases[0].get("status") == "run" and
            all(cases[0].find(tag) is None for tag in ("failure", "error", "skipped")),
            "Native CTest predication executable did not run successfully")
    return report


def verify_sessions(content):
    report = parse_json(content)
    tests = report.get("Tests", [])
    names = [case.get("Name") for case in tests]
    require(report.get("WindowsPowerShell51") is True and
            str(report.get("PowerShellVersion", "")).startswith("5.1.") and
            report.get("Failed") == 0 and report.get("Passed") == len(tests) and
            len(set(names)) == len(names) and REQUIRED_SESSION_CASES.issubset(names) and
            all(case.get("Status") == "PASS" for case in tests),
            "Current-session evidence checks require passing native Windows PowerShell 5.1 results")
    require("provided-private-evidence-current-session-regression" not in names,
            "Do not bundle private user-evidence runs in the public CI package")
    return report


def wrapper(script, action, preserve_effect=False):
    content = _base.wrapper(script, action)
    if preserve_effect:
        content = content.replace(b"-Action Apply", b"-Action Apply -PreserveEffect")
    return content


def main():
    parser = argparse.ArgumentParser()
    for name in ("base-zip", "source-root", "output", "handoff-results", "control-results",
                 "predication-results", "session-results"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args()
    require(re.fullmatch(r"[0-9a-f]{40}", args.source_commit), "A fixed source SHA is required")
    require(re.fullmatch(r"[0-9]+", args.run_id), "A numeric Windows CI run ID is required")
    require(not args.output.exists(), "Refusing to overwrite an existing output ZIP")
    root = args.source_root.resolve(strict=True)
    base_bytes = args.base_zip.read_bytes()
    base = unroot(archive_files(base_bytes))
    manifest_bytes = base["package-manifest.json"]
    manifest = parse_json(manifest_bytes)
    run_url = "https://github.com/lunarci/b/actions/runs/" + args.run_id
    require(manifest.get("schema_version") == 1 and manifest.get("addon_name") == "MatheusNR030" and
            manifest.get("base_nr_sha256") == _base.NR_SHA and manifest.get("source_commit") == args.source_commit and
            str(manifest.get("build_run_id")) == args.run_id and manifest.get("build_evidence") == run_url and
            manifest.get("runtime_log_schema") == "matheusnr030-events-v1" and
            manifest.get("build_verified") is True and manifest.get("abi_verified") is True and
            manifest.get("game_runtime_verified") is False and bool(manifest.get("abi_evidence")),
            "CI manifest does not match the requested verified build/source")
    provenance = parse_json(base["BUILD_PROVENANCE.json"])
    require(provenance.get("source_commit") == args.source_commit and
            str(provenance.get("build_run_id")) == args.run_id and
            provenance.get("runtime_enabled_at_build") is True and provenance.get("amd_gpu_game_tested") is False,
            "CI provenance does not match the requested runtime-enabled build")
    entries = manifest.get("files", [])
    require(len(entries) == 2 and {entry.get("name") for entry in entries} == set(_base.PAYLOADS),
            "Exactly the two declared add-on payload files are required")
    for entry in entries:
        content = base["payload/" + entry["name"]]
        require(entry.get("sha256") == digest(content) and entry.get("size") == len(content),
                "Payload integrity mismatch: " + entry["name"])
    asi = base["payload/MatheusNR030.asi"]
    require(len(asi) >= 64 and asi[:2] == b"MZ", "ASI is not a PE image")
    pe = struct.unpack_from("<I", asi, 60)[0]
    require(pe <= len(asi) - 24 and asi[pe:pe + 4] == b"PE\0\0" and
            struct.unpack_from("<H", asi, pe + 4)[0] == 0x8664 and
            struct.unpack_from("<H", asi, pe + 22)[0] & 0x2000 and
            digest(asi) != _base.BASELINE_SHA and args.source_commit.encode("ascii") in asi,
            "Expected a rebuilt Windows x64 add-on embedding the requested source commit")
    require(b"event=predication_stats" in asi and b"admission=observed_disabled_only" in asi,
            "The rebuilt ASI lacks predication guard diagnostics")
    ctest = base["evidence/ctest-results.xml"]
    handoff_bytes = args.handoff_results.read_bytes()
    control_bytes = args.control_results.read_bytes()
    predication_bytes = args.predication_results.read_bytes()
    session_bytes = args.session_results.read_bytes()
    handoff = _base.verify_handoff(handoff_bytes, ctest)
    controls = _base.verify_control(control_bytes)
    require(controls.get("NativeEffectApiVerified") is True and REQUIRED_PRESERVE_CASES.issubset(
            {case["Name"] for case in controls["Tests"]}),
            "Native INI API and preserve-effect installation regressions are required")
    predication = verify_predication(predication_bytes, ctest)
    sessions = verify_sessions(session_bytes)
    for relative, content in (
        ("evidence/package-tests/original-color-control-tests.json", control_bytes),
        ("evidence/package-tests/session-evidence-tests.json", session_bytes),
        ("evidence/predication_results.json", predication_bytes),
    ):
        require(base.get(relative) == content, "Evidence differs from the matching CI package: " + relative)
    compiled = archive_files(base["SOURCE.zip"])
    for relative in ("addon/MatheusNR030.cpp", "addon/predication.h", "addon/predication.cpp", "addon/predication_checks.cpp",
                     "addon/handoff_checks.cpp", "addon/lifetime.cpp", "addon/lifetime.h", "addon/CMakeLists.txt",
                     "runtime_contract.h", "package/Test-Original-Color-Control.ps1",
                     "package/Test-Session-Evidence.ps1", "tools/Build-PredicationFix-Package.py",
                     "tools/Build-OriginalColor-Package.py", "predication-fix/README_KO.md"):
        require(compiled.get("nr030-matheus/" + relative) == (root / relative).read_bytes(),
                "Local source differs from the compiled source archive: " + relative)
    files = {}
    for name, content in base.items():
        if (name in ("SOURCE.zip", "protected-files.json", "LICENSE", "NOTICE") or
                name in {"payload/" + item for item in _base.PAYLOADS} or
                name.startswith(("third_party/", "evidence/"))):
            files[name] = content
    for name in _base.SCRIPTS:
        content = (root / "package" / name).read_bytes()
        require(compiled.get("nr030-matheus/package/" + name) == content,
                "Installer differs from the compiled source archive: " + name)
        files[name] = content
    files["README_KO.md"] = (root / "predication-fix/README_KO.md").read_bytes()
    files["evidence/CI-package-manifest.json"] = manifest_bytes
    files["evidence/CI-BUILD_PROVENANCE.json"] = base["BUILD_PROVENANCE.json"]
    files["evidence/handoff_results.json"] = handoff_bytes
    manifest["addon_version"] = "0.2.4-predication-fix"
    files["package-manifest.json"] = json_bytes(manifest)
    files["01_APPLY_FIX.cmd"] = wrapper("Original-Color-Control.ps1", "Apply", True)
    files["02_RESTORE_PREVIOUS.cmd"] = wrapper("Original-Color-Control.ps1", "Restore")
    files["03_COLLECT_LOGS.cmd"] = wrapper("Motion-Tuning.ps1", "Collect")
    files["BUILD_PROVENANCE.json"] = json_bytes({
        "name": NAME, "purpose": "Guard NR dispatch admission and known-disabled GPU predication state",
        "source_commit": args.source_commit,
        "source": "https://github.com/lunarci/b/tree/" + args.source_commit + "/nr030-matheus",
        "build_run_id": args.run_id, "workflow": run_url,
        "ci_base_package_sha256": digest(base_bytes), "adapter_sha256": digest(asi),
        "adapter_rebuilt": True,
        "predication_strategy": "Admit NR only for an observed disabled predicate; preserve active/unknown caller state by passing that dispatch directly to original FSR",
        "restore_strategy": "Restore known-disabled predication before original FSR; never rebind a non-null predicate buffer",
        "all_ini_settings_preserved_on_apply": True, "effect_percent_forced": False,
        "required_existing_scale_percent": 85, "xefg_configuration_changed": False,
        "nr_or_model_downloaded_or_replaced": False, "upscaler_binaries_replaced": False,
        "payload_ini_role": "CI payload integrity validation only; apply does not install this INI",
        "native_predication_cases": predication["passedCount"], "native_handoff_cases": handoff["passedCount"],
        "windows_powershell51_control_cases": controls["Passed"],
        "windows_powershell51_session_cases": sessions["Passed"],
        "restore": "Preserves the existing backup chain; any prior Effect restoration ownership is retained",
        "game_runtime_verified": False, "visual_improvement_verified": False,
        "latency_improvement_verified": False,
        "files": {name: digest(content) for name, content in sorted(files.items())},
    })
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, "x", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, content in sorted(files.items()):
            archive.writestr(NAME + "/" + name, content)
    print(json.dumps({"file": str(args.output), "size": args.output.stat().st_size,
                      "sha256": digest(args.output.read_bytes()), "source_commit": args.source_commit}))


if __name__ == "__main__":
    main()
