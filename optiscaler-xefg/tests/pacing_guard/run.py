#!/usr/bin/env python3
"""Build guard policy and actual production callback regressions on Windows/Linux."""
from pathlib import Path
import argparse
import os
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("source_dir", type=Path)
args = parser.parse_args()
source = args.source_dir.resolve() / "OptiScaler"
here = Path(__file__).resolve().parent

with tempfile.TemporaryDirectory(prefix="xefg-pacing-guard-") as directory:
    temp = Path(directory)
    callbacks = temp / "callbacks.cpp"
    subprocess.run([sys.executable, str(here / "test_xefg_pacing_extracted.py"),
                    str(args.source_dir.resolve()), "--emit", str(callbacks)], check=True)
    for name, cpp in [("policy", here / "xefg_pacing_guard_tests.cpp"), ("callbacks", callbacks)]:
        binary = temp / (name + (".exe" if os.name == "nt" else ""))
        if os.name == "nt":
            command = ["cl", "/nologo", "/std:c++20", "/EHsc", "/W4",
                       "/I" + str(source / "proxies"), "/I" + str(source),
                       str(cpp), "/Fe:" + str(binary)]
        else:
            command = [os.environ.get("CXX", "g++"), "-std=c++20", "-Wall", "-Wextra", "-Werror",
                       "-fsanitize=undefined", "-fno-sanitize-recover=all", "-pthread",
                       "-I", str(source / "proxies"), "-I", str(source),
                       str(cpp), "-o", str(binary)]
        subprocess.run(command, cwd=temp, check=True)
        subprocess.run([str(binary)], check=True)
print("Scope: production pacing callbacks with deterministic CPU mocks; no game/GPU performance claim.")
