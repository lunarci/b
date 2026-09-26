#!/usr/bin/env python3
"""Compile actual R7 progress methods against explicit CPU/COM boundaries."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("r7_progress_helpers", HERE.parent / "r4_resource_safety/run.py")
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
BASELINE_HASH = "349d2e6d9b7e74eb0a31bfbed9d92455144f633cffa677534ef403b1167a3ed3"


def negative_control(source):
    data = (HERE / "r6_pending_baseline.json").read_bytes().replace(b"\r\n", b"\n")
    assert hashlib.sha256(data).hexdigest() == BASELINE_HASH, "Pinned R6 source fixture changed"
    fixture = json.loads(data)
    harness = (HERE / "pending_baseline_harness.cpp").read_text(encoding="utf-8")
    program = harness.replace("// ACTUAL_FUNCTIONS", "\n".join(fixture["functions"].values()))
    helpers.compile_and_run(source, program, "verified R6 negative control: late After erases a new recording",
                            expected_exit=42, expected_output="fg.PendingForTest()")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    source = args.source.resolve()
    negative_control(source)
    cpp = (source / "OptiScaler/framegen/xefg/XeFG_Dx12.cpp").read_text(encoding="utf-8-sig")
    header = (source / "OptiScaler/framegen/xefg/XeFG_Dx12.h").read_text(encoding="utf-8-sig")
    functions = [helpers.extract_function(cpp, signature) for signature in (
        "void XeFG_Dx12::TrackLifetimeQueue(",
        "void XeFG_Dx12::ObserveSubmittedQueue(",
        "void XeFG_Dx12::PollGpuProgress()",
        "void XeFG_Dx12::PollGpuProgressLocked(",
        "void XeFG_Dx12::PublishGpuProgressLocked(",
        "void XeFG_Dx12::ReleaseObjects()",
    )]
    entry = helpers.extract_function(header, "struct LifetimeQueue") + ";"
    harness = (HERE / "progress_harness.cpp").read_text(encoding="utf-8")
    program = harness.replace("// ACTUAL_QUEUE_ENTRY", entry)
    program = program.replace("// ACTUAL_FUNCTIONS", "\n".join(functions))
    program = program.replace("// TEST_BODY", (HERE / "progress_tests.cpp").read_text(encoding="utf-8"))
    helpers.compile_and_run(source, program, "actual R7 queue progress observation and lifetime boundaries")


if __name__ == "__main__":
    main()
