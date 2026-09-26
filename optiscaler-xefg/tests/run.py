#!/usr/bin/env python3
"""Run production-code regression suites; this does not run the game or GPU FG."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--runtime-dir", type=Path)
    args = parser.parse_args()
    source = args.source.resolve()
    here = Path(__file__).resolve().parent
    if os.name == "nt" and shutil.which("cl") is None:
        vswhere = Path(os.environ["ProgramFiles(x86)"]) / "Microsoft Visual Studio/Installer/vswhere.exe"
        installation = subprocess.check_output([
            str(vswhere), "-latest", "-products", "*", "-requires",
            "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"
        ], text=True).strip()
        if not installation:
            raise RuntimeError("MSVC toolchain not found for the regression suites")
        developer_cmd = Path(installation) / "Common7/Tools/VsDevCmd.bat"
        environment = subprocess.check_output(
            f'call "{developer_cmd}" -no_logo -arch=x64 -host_arch=x64 >nul && set',
            shell=True, text=True
        )
        for line in environment.splitlines():
            if "=" in line and not line.startswith("="):
                key, value = line.split("=", 1)
                os.environ[key] = value
    suites = [
        ("XeFG resource state guard: 96 production-code scenarios", here / "barrier/test_resource_guard.py"),
        ("MFG unlock: 11 fault scenarios and real Intel DLL patch sites", here / "unlock/run.py"),
        ("Game-facing capability initialization and configured maximum", here / "capabilities/run.py"),
        ("Pacing epochs, fresh estimates and input-time priority", here / "pacing/run.py"),
        ("History reset handoff and valid runtime motion metadata", here / "history/run.py"),
        ("FFX input, exposure and copy resource-state guards", here / "exposure/run.py"),
        ("Long-session memory pressure and bounded timing diagnostics", here / "long_session/run.py"),
        ("Long-stall pacing recovery and native-forward guards", here / "pacing_guard/run.py"),
        ("Descriptor metadata publication without registry-lock allocation", here / "tracking/run.py"),
        ("Owned-copy allocation failures and safe GPU/provider teardown", here / "memory_lifetime/run.py"),
        ("R4 copied-resource retagging and concurrent lifecycle admission", here / "r4_resource_safety/run.py"),
        ("R5 installed lifetime observers, playable recovery and release propagation", here / "r5_lifetime_recovery/run.py"),
        ("R6 coherent recovery, native provider status and memory error reporting", here / "r6_recovery/run.py"),
        ("FFX context registry concurrency and atomic removal", here / "r6_ffx_registry/run.py"),
        ("R7 sparse GPU progress, bounded observation and lifecycle safety", here / "r7_progress/run.py"),
        ("R7 native submission observation and generation ticket ordering", here / "r7_tracking/run.py"),
        ("R7 allocation provenance, bounded accounting and observer timing", here / "r7_allocation/run.py"),
    ]
    report = {"passed": False, "gpu_game_tested": False, "tests": []}
    try:
        for title, script in suites:
            command = [sys.executable, str(script), str(source)]
            if args.runtime_dir and script.parent.name == "unlock":
                command.extend(["--runtime-dir", str(args.runtime_dir.resolve())])
            started = time.monotonic()
            result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            print(result.stdout, end="", flush=True)
            report["tests"].append({"name": title, "passed": result.returncode == 0,
                                    "seconds": round(time.monotonic() - started, 3),
                                    "output": result.stdout})
            if result.returncode:
                raise RuntimeError(f"Regression suite failed: {title}")
        report["passed"] = True
    finally:
        (source / "JAEYUN_TEST_RESULTS.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("PASS: all code regression suites; actual GPU/game execution remains untested.")


if __name__ == "__main__":
    main()
