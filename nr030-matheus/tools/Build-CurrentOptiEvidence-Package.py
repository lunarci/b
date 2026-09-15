"""Package current Opti evidence collection against matching Windows CI source."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import zipfile

NAME = "OptiScaler_Current_Evidence"
BASE_SHA = "8f914002d8d832810207413978f7d93db8680a31a122f28a516ad41fe577e5e9"
SCRIPTS = ("Setup.ps1", "Complete-Setup.ps1", "Motion-Tuning.ps1", "Opti-Log-Control.ps1",
           "Collect-Opti-RuntimeEvidence.ps1")
TESTS = ("Test-Motion-Tuning.ps1", "Test-Opti-Log-Control.ps1", "Test-Complete-Package.ps1",
         "Test-Opti-RuntimeEvidence.ps1")
REPORTS = ("motion-tuning-tests.json", "opti-log-control-tests.json",
           "complete-installer-tests.json", "opti-runtime-evidence-tests.json")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_json(data):
    return json.loads(data.decode("utf-8-sig"))


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def cmd(script, action):
    argument = " -Action " + action if action else ""
    call = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0' + script + '"' + argument
    return ("@echo off\nsetlocal DisableDelayedExpansion\nif \"%~1\"==\"\" (\n  " + call +
            '\n) else (\n  ' + call + ' -Mo2Root "%~1"\n)\nset "diagnostic_exit=%ERRORLEVEL%"\n'
            'pause\nexit /b %diagnostic_exit%\n').replace("\n", "\r\n").encode("ascii")


def main():
    parser = argparse.ArgumentParser()
    for option in ("base-zip", "evidence-dir", "output"):
        parser.add_argument("--" + option, required=True, type=Path)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args()
    require(re.fullmatch(r"[0-9a-f]{40}", args.source_commit), "Exact source commit required")
    require(args.run_id.isdigit() and not args.output.exists(), "Invalid run or existing output")
    component = Path(__file__).resolve().parents[1]
    evidence = args.evidence_dir
    context_bytes = (evidence / "current-evidence-ci-context.json").read_bytes()
    context = read_json(context_bytes)
    require(context["SourceCommit"] == args.source_commit and str(context["RunId"]) == args.run_id,
            "CI source/run does not match")
    sources = {}
    for relative in (["package/" + name for name in SCRIPTS + TESTS] +
                     ["tools/Build-CurrentOptiEvidence-Package.py", "current-opti-evidence/README_KO.md"]):
        data = (component / relative).read_bytes()
        require(context["Files"].get(relative) == sha(data), "Source differs from CI: " + relative)
        sources[relative] = data
    files = {name: sources["package/" + name] for name in SCRIPTS}
    summaries = {}
    for name in REPORTS:
        data = (evidence / name).read_bytes()
        report = read_json(data)
        tests = report.get("Tests", [])
        require(report.get("WindowsPowerShell51") is True and report.get("Failed") == 0 and
                tests and report.get("Passed") == len(tests) and
                all(case.get("Status") == "PASS" for case in tests), "Windows tests did not pass: " + name)
        if name == "opti-log-control-tests.json":
            require(report.get("ParserCompatible") is True and report["Passed"] == 8,
                    "Native SimpleIni parser verification missing")
        if name == "opti-runtime-evidence-tests.json":
            require(report["Passed"] == 10, "Runtime collection regression cases missing")
        if name == "complete-installer-tests.json":
            require(report["Passed"] >= 33 and {
                "ratio-check-interprets-auto-and-missing-per-preset-default-with-raw-evidence",
                "ratio-check-default-per-preset-retains-global-and-numeric-gates"
            }.issubset({case["Name"] for case in tests}), "Ratio regression cases missing")
        summaries[name] = report["Passed"]
        files["evidence/" + name] = data
    files["evidence/current-evidence-ci-context.json"] = context_bytes
    base_bytes = args.base_zip.read_bytes()
    require(sha(base_bytes) == BASE_SHA, "Wrong verification baseline")
    with zipfile.ZipFile(io.BytesIO(base_bytes)) as archive:
        require(archive.testzip() is None, "Corrupt baseline ZIP")
        prefix = "Matheus_NR030_PredicationFix/"
        for name in ("package-manifest.json", "protected-files.json", "LICENSE", "NOTICE",
                     "payload/MatheusNR030.asi", "payload/MatheusNR030.ini"):
            files[name] = archive.read(prefix + name)
        files["baseline/SOURCE.zip"] = archive.read(prefix + "SOURCE.zip")
        files["baseline/BUILD_PROVENANCE.json"] = archive.read(prefix + "BUILD_PROVENANCE.json")
    source_zip = io.BytesIO()
    with zipfile.ZipFile(source_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(sources.items()):
            archive.writestr("nr030-matheus/" + name, data)
    files["CONTROL_SOURCE.zip"] = source_zip.getvalue()
    files["README_KO.md"] = sources["current-opti-evidence/README_KO.md"]
    files["01_ENABLE_CURRENT_LOG.cmd"] = cmd("Opti-Log-Control.ps1", "Enable")
    files["02_COLLECT_CURRENT_EVIDENCE.cmd"] = cmd("Collect-Opti-RuntimeEvidence.ps1", None)
    files["03_RESTORE_LOG_SETTINGS.cmd"] = cmd("Opti-Log-Control.ps1", "Restore")
    files["DIAGNOSTIC_PROVENANCE.json"] = json_bytes({
        "name": NAME, "purpose": "Enable current logs and collect exact OptiScaler binary for analysis",
        "source_commit": args.source_commit, "windows_run_id": args.run_id,
        "windows_run": "https://github.com/lunarci/b/actions/runs/" + args.run_id,
        "tests_passed": summaries, "logging_keys_changed": ["LogToFile", "LogLevel", "LogFileName"],
        "nr_settings_changed": False, "xefg_settings_changed": False, "binaries_installed": False,
        "game_runtime_verified": False, "graphics_fix": False,
        "verification_baseline_sha256": BASE_SHA,
        "files": {name: sha(data) for name, data in sorted(files.items())}
    })
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, "x", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(files.items()):
            archive.writestr(NAME + "/" + name, data)
    print(json.dumps({"path": str(args.output), "size": args.output.stat().st_size,
                      "sha256": sha(args.output.read_bytes())}))


if __name__ == "__main__":
    main()
