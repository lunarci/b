#!/usr/bin/env python3
"""Compile the exact production FFX context routing registry under contention."""
import argparse
import importlib.util
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("r6_registry_helpers", HERE.parent / "r4_resource_safety/run.py")
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    source = parser.parse_args().source.resolve()
    proxy = (source / "OptiScaler/proxies/FfxApi_Proxy.h").read_text(encoding="utf-8")
    accesses = re.findall(r"contextToType\s*(?:\.\s*(\w+)|\[)", proxy)
    assert sorted(accesses) == ["Find", "Set", "Set", "Set", "Set", "Take"], accesses
    assert "FfxContextRegistry<ankerl::unordered_dense::map<ffxContext, FFXStructType>>" in proxy
    # These helpers return copied metadata only; SDK calls stay at their existing
    # call sites after the registry operation, outside the mutex's lifetime.
    helper = (source / "OptiScaler/proxies/FfxContextRegistry.h").read_text(encoding="utf-8")
    assert "CreateContext(" not in helper and "DestroyContext(" not in helper and "Configure(" not in helper
    helpers.compile_and_run(source, (HERE / "registry.cpp").read_text(encoding="utf-8"),
                            "FFX registry: actual production helper and all six proxy accesses")


if __name__ == "__main__":
    main()
