"""Package a version-gated XeFG barrier correction from matching Windows CI."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

SPEC = importlib.util.spec_from_file_location(
    "predication_packaging", Path(__file__).with_name("Build-PredicationFix-Package.py"))
PRED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PRED)
require, digest, parse_json, json_bytes = PRED.require, PRED.digest, PRED.parse_json, PRED.json_bytes
NAME = "Matheus_NR030_XeFGBarrierGuard"
HOST_SHA = "ba4df99acf55278c617780d56b89847553063ebc8e521bf831e09d21d5c0b04b"


def main():
    parser = argparse.ArgumentParser()
    for name in ("base-zip", "source-root", "output", "handoff-results", "control-results",
                 "predication-results", "session-results", "guard-results"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args()
    require(not args.output.exists(), "Refusing to overwrite an existing package")
    root = args.source_root.resolve(strict=True)
    # Reuse the existing complete binary/source/ownership/handoff/predication
    # gates. The intermediate package is private to this build operation.
    with tempfile.TemporaryDirectory(prefix="xefg-package-") as folder:
        intermediate = Path(folder) / "validated-baseline.zip"
        command = [sys.executable, str(Path(__file__).with_name("Build-PredicationFix-Package.py"))]
        for name in ("base-zip", "source-root", "handoff-results", "control-results",
                     "predication-results", "session-results", "source-commit", "run-id"):
            command += ["--" + name, str(getattr(args, name.replace("-", "_")))]
        command += ["--output", str(intermediate)]
        subprocess.run(command, check=True)
        files = PRED.unroot(PRED.archive_files(intermediate.read_bytes()))
    compiled = PRED.archive_files(files["SOURCE.zip"])
    for relative in ("addon/xefg_barrier_guard.h", "addon/xefg_barrier_guard.cpp",
                     "addon/xefg_barrier_guard_checks.cpp", "addon/MatheusNR030.cpp",
                     "addon/CMakeLists.txt", "tools/Build-XeFGBarrierGuard-Package.py",
                     "xefg-barrier-guard/README_KO.md", "package/Test-XeFG-Guard-Package.ps1"):
        require(compiled.get("nr030-matheus/" + relative) == (root / relative).read_bytes(),
                "Source differs from compiled archive: " + relative)
    guard_bytes = args.guard_results.read_bytes()
    guard = parse_json(guard_bytes)
    tests = guard.get("tests", [])
    names = [case.get("name") for case in tests]
    require(guard.get("success") is True and guard.get("failedCount") == 0 and
            guard.get("debugLayerEnabled") is True and guard.get("amdGpuGameTested") is False and
            guard.get("passedCount") == len(names) and len(names) >= 17 and
            len(set(names)) == len(names) and all(case.get("passed") is True and
            case.get("error") == "" for case in tests) and {
                "warp-unfiltered-duplicate-produces-debug-state-mismatch",
                "warp-filtered-modern-sequence-has-valid-state-and-exact-readback",
                "warp-legacy-paired-transitions-remain-valid-and-unmodified",
                "warp-other-caller-required-transition-is-preserved",
            }.issubset(names), "XeFG guard tests did not pass")
    suite = ET.fromstring(files["evidence/ctest-results.xml"])
    matches = [case for case in suite.findall("testcase")
               if case.get("name") == "nr030_xefg_barrier_checks"]
    require(len(matches) == 1 and matches[0].get("status") == "run" and
            all(matches[0].find(tag) is None for tag in ("failure", "error", "skipped")),
            "The native XeFG barrier test did not run")
    require(files.get("evidence/xefg_barrier_results.json") == guard_bytes,
            "Guard evidence differs from native build package")
    asi = files["payload/MatheusNR030.asi"]
    require(b"xefg_barrier_guard" in asi and HOST_SHA.encode() in asi,
            "ASI lacks the exact-host guard and diagnostic marker")
    for name in ("Collect-Opti-RuntimeEvidence.ps1",):
        data = (root / "package" / name).read_bytes()
        require(compiled.get("nr030-matheus/package/" + name) == data,
                "Collector differs from compiled source")
        files[name] = data
    files["README_KO.md"] = (root / "xefg-barrier-guard/README_KO.md").read_bytes()
    files["03_COLLECT_LOGS.cmd"] = PRED.wrapper("Collect-Opti-RuntimeEvidence.ps1", "Collect")
    manifest = parse_json(files["package-manifest.json"])
    manifest["addon_version"] = "0.2.4-xefg-barrier-guard"
    files["package-manifest.json"] = json_bytes(manifest)
    provenance = parse_json(files.pop("BUILD_PROVENANCE.json"))
    provenance.update({
        "name": NAME,
        "purpose": "Correct one unmatched XeFG COPY_DEST-to-COPY_SOURCE restoration for SDK >= 1.2.2",
        "exact_optiscaler_sha256": HOST_SHA,
        "guard_return_rva": "0x126D72",
        "native_xefg_barrier_cases": len(names),
        "guard_coverage": "ResourceBarrier implementation observed on the admitted FFX command list",
        "guard_counters_required": True,
        "zero_suppressions_mean": "No triggering of this guarded defect was observed; no visual success claim",
        "older_provider_barriers_preserved": True,
        "caller_predication_policy_unchanged": True,
        "game_runtime_verified": False,
        "visual_improvement_verified": False,
        "latency_improvement_verified": False,
        "files": {name: digest(data) for name, data in sorted(files.items())},
    })
    files["BUILD_PROVENANCE.json"] = json_bytes(provenance)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, "x", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(files.items()):
            archive.writestr(NAME + "/" + name, data)
    print(json.dumps({"file": str(args.output), "size": args.output.stat().st_size,
                      "sha256": digest(args.output.read_bytes()), "source_commit": args.source_commit}))


if __name__ == "__main__":
    main()
