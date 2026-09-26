#!/usr/bin/env python3
"""Exercise production LongSession state/timing headers without Windows or a GPU.

The parent tests/run.py initializes the shared MSVC environment on Windows.
DXGI collection/integration is checked by the full Windows OptiScaler build;
these tests do not claim to execute the driver or the game.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
parser.add_argument("--cxx")
args = parser.parse_args()
include = args.source.resolve() / "OptiScaler/misc"
for filename in ("LongSessionState.h", "LongSessionTiming.h"):
    if not (include / filename).is_file():
        parser.error(f"missing production header: {include / filename}")

compiler = args.cxx or (shutil.which("cl") if os.name == "nt" else shutil.which("c++"))
if not compiler:
    parser.error("C++ compiler required; run through tests/run.py for MSVC environment setup")
cpp = Path(__file__).resolve().with_name("long_session_state_test.cpp")
with tempfile.TemporaryDirectory(prefix="long-session-tests-") as tmp:
    directory = Path(tmp)
    executable = directory / ("long-session.exe" if os.name == "nt" else "long-session")
    if Path(compiler).name.lower() in ("cl", "cl.exe"):
        command = [compiler, "/nologo", "/std:c++17", "/EHsc", "/W4", "/WX", "/UNDEBUG",
                   "/I" + str(include), str(cpp), "/Fe:" + str(executable),
                   "/Fo:" + str(directory / "long-session.obj")]
    else:
        command = [compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", "-UNDEBUG",
                   "-I", str(include), str(cpp), "-o", str(executable)]
    subprocess.run(command, cwd=directory, check=True)
    subprocess.run([str(executable)], check=True)

subprocess.run([sys.executable, str(Path(__file__).with_name("monitor_log_test.py")), str(args.source.resolve())], check=True)
