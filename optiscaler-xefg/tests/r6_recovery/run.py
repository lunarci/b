#!/usr/bin/env python3
"""R6 recovery regressions extract production functions; external SDK/COM are fakes."""
import argparse
import hashlib
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("r6_test_helpers", HERE.parent / "r4_resource_safety/run.py")
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
BASELINE_HASH = "8dcb1562482481f45aa3cdbe84a3e119f6ac803e9fad7af851365b9edf9fc289"
NEGATIVE_ASSERT = r'''
#include <cstdlib>
#undef assert
#define assert(condition) do { if (!(condition)) { std::cerr << "R5 invariant failure: " << #condition << "\n"; std::exit(42); } } while(false)
'''


def baseline_fixture():
    # Git on Windows may checkout CRLF. Pin semantic source bytes, normalized LF.
    data = (HERE / "r5_baseline.json").read_bytes().replace(b"\r\n", b"\n")
    if hashlib.sha256(data).hexdigest() != BASELINE_HASH:
        raise AssertionError("Verified R5 baseline identity changed")
    return json.loads(data)["files"]


def baseline_resource_program(test):
    fixture = baseline_fixture()
    functions = fixture["OptiScaler/framegen/xefg/XeFG_Dx12.cpp"]["functions"]
    base = fixture["OptiScaler/framegen/IFGFeature_Dx12.cpp"]["functions"]
    inline_failure = fixture["OptiScaler/framegen/xefg/XeFG_Dx12.h"]["functions"]["void RecordCopyAllocationFailure()"]
    harness = (HERE / "resource_harness.cpp").read_text(encoding="utf-8")
    harness = harness.replace("// ACTUAL_INLINE_FAILURE_HANDLER", inline_failure.replace(" override final", ""))
    harness = harness.replace("// ACTUAL_FUNCTIONS", "\n".join([*functions.values(), *base.values()]))
    return ("#define R4_SOURCE 1\n#define R5_SOURCE 1\n" + harness
            .replace("// ASSERT_SHIM", NEGATIVE_ASSERT).replace("// TEST_BODY", test))


FORMAT_REPEATS = r'''
int main() {
    XeFG_Dx12 subject; ID3D12Resource resource; Dx12Resource input;
    input.resource=&resource; input.validity=FG_ResourceValidity::UntilPresentFromDispatch;
    assert(subject.SetResource(&input));
    resource.format=87;
    unsigned acceptedNewFormat=0, restartRequests=0;
    for(unsigned frame=0;frame<100;++frame) {
        subject._frameResources[0].clear(); subject._resourceReady[0].clear();
        subject._noHudless[0]=true; ++subject._frameCount;
        State::Instance().fgChanged=false;
        acceptedNewFormat += subject.SetResource(&input) ? 1u : 0u;
        restartRequests += State::Instance().fgChanged ? 1u : 0u;
    }
    assert(acceptedNewFormat > 0 && "same changed format must eventually converge");
    assert(restartRequests <= 1 && "one format transition cannot restart every frame");
}
'''
FAILED_TAG_ENTRY = r'''
int main() {
    XeFG_Dx12 subject; ID3D12Resource resource; Dx12Resource input;
    input.resource=&resource;input.type=FG_ResourceType::Depth;
    XeFGProxy::failTag=true;
    assert(!subject.SetResource(&input));
    assert(!subject._frameResources[0].contains(FG_ResourceType::Depth) && "failed SDK tag must not poison slot");
    assert(!subject._resourceReady[0].contains(FG_ResourceType::Depth));
    assert(!State::Instance().fgChanged && "local tag failure cannot drive global restart feedback");
}
'''


def negative_controls(source):
    for title, test, expected in [
        ("100 repeated changed-format frames converge", FORMAT_REPEATS, "acceptedNewFormat > 0"),
        ("SDK tag failure removes the failed Depth entry", FAILED_TAG_ENTRY,
         "!subject._frameResources[0].contains(FG_ResourceType::Depth)"),
    ]:
        helpers.compile_and_run(source, baseline_resource_program(test), "verified R5 negative control: " + title,
                                expected_exit=42, expected_output=expected)


def production_pipeline(source):
    cpp=(source/"OptiScaler/framegen/xefg/XeFG_Dx12.cpp").read_text(encoding="utf-8-sig")
    header=(source/"OptiScaler/framegen/xefg/XeFG_Dx12.h").read_text(encoding="utf-8-sig")
    base=(source/"OptiScaler/framegen/IFGFeature_Dx12.cpp").read_text(encoding="utf-8-sig")
    signatures=["bool XeFG_Dx12::SetResource(","void XeFG_Dx12::RecordCopyAllocation(",
       "bool XeFG_Dx12::TryBeginRecoveryTrial(","void XeFG_Dx12::NoteRecoveryFault(",
       "void XeFG_Dx12::PreparePresent()","void XeFG_Dx12::ReportFormatTransition(","void XeFG_Dx12::MarkFrameConstantsReady(",
       "UINT64 XeFG_Dx12::PresentRecoveryToken()","void XeFG_Dx12::ObservePresentStatus(",
       "void XeFG_Dx12::Activate()","bool XeFG_Dx12::Dispatch()"]
    functions=[helpers.extract_function(cpp,"static bool IsTerminalXeFGResult(")] + [helpers.extract_function(cpp,sig) for sig in signatures]
    functions.append(helpers.extract_function(base,"void IFGFeature_Dx12::FlipResource("))
    general=(source/"OptiScaler/framegen/IFGFeature.cpp").read_text(encoding="utf-8-sig")
    functions.append(helpers.extract_function(general,"int IFGFeature::GetDispatchIndex("))
    inline_failure=helpers.extract_function(header,"void RecordCopyAllocationFailure()").replace(" override final","")
    harness=(HERE/"pipeline_harness.cpp").read_text(encoding="utf-8")
    harness=harness.replace("// ACTUAL_INLINE_FAILURE_HANDLER",inline_failure).replace("// ACTUAL_FUNCTIONS","\n".join(functions))
    harness=harness.replace("// TEST_BODY",(HERE/"pipeline_tests.cpp").read_text(encoding="utf-8"))
    helpers.compile_and_run(source,"#define R4_SOURCE 1\n#define R5_SOURCE 1\n#define DONT_USE_XMX 1\n"+harness,
                            "actual resource-dispatch-recovery pipeline")

def frame_boundary(source):
    paths=[("OptiScaler/framegen/IFGFeature.cpp",["UINT64 IFGFeature::StartNewFrame()","void IFGFeature::SetFrameCount(","int IFGFeature::GetDispatchIndex("]),
           ("OptiScaler/framegen/xefg/XeFG_Dx12.cpp",["UINT64 XeFG_Dx12::StartNewFrame()","void XeFG_Dx12::SetFrameCount("]),
           ("OptiScaler/inputs/FG/Streamline_Inputs_Sl1_Dx12.cpp",["void Sl1_Inputs_Dx12::CheckForFrame("])]
    functions=[]
    for path,signatures in paths:
        text=(source/path).read_text(encoding="utf-8-sig")
        functions.extend(helpers.extract_function(text,signature) for signature in signatures)
    program=(HERE/"frame_boundary.cpp").read_text(encoding="utf-8").replace("// ACTUAL_FUNCTIONS","\n".join(functions))
    helpers.compile_and_run(source,program,"actual SL1 frame boundary and XeFG recovery rebase")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--baseline-only", action="store_true")
    args = parser.parse_args()
    source = args.source.resolve()
    negative_controls(source)
    if not args.baseline_only:
        for filename,title in [("recovery_policy.cpp","production recovery policy"),
                               ("present_diagnostics.cpp","production present and input diagnostics")]:
            helpers.compile_and_run(source,(HERE/filename).read_text(encoding="utf-8"),title)
        residency=(source/"OptiScaler/hooks/D3D12_Hooks.cpp").read_text(encoding="utf-8-sig")
        program=(HERE/"residency.cpp").read_text(encoding="utf-8").replace("// ACTUAL_FUNCTION",
            helpers.extract_function(residency,"static HRESULT hkSetResidencyPriority("))
        helpers.compile_and_run(source,program,"actual native residency error propagation")
        production_pipeline(source)
        frame_boundary(source)
        subprocess.run([sys.executable,str(HERE/"allocation_observer_test.py"),str(source)],check=True)
        print("PASS: all R6 recovery, provider-status, residency and allocation regressions")


if __name__ == "__main__":
    main()
