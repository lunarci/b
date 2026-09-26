#!/usr/bin/env python3
"""Exercise the production reset latch and actual SL auto-metadata code."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
args = parser.parse_args()
root = args.source.resolve()
sl_source = (root / "OptiScaler/inputs/FG/Streamline_Inputs_Dx12.cpp").read_text(encoding="utf-8-sig")
config = (root / "OptiScaler/Config.h").read_text(encoding="utf-8-sig")
ifg_source = (root / "OptiScaler/framegen/IFGFeature.cpp").read_text(encoding="utf-8-sig")
optional_code = config[config.index("enum HasDefaultValue"):config.index("constexpr inline int UnboundKey")]

def function(text, signature):
    start = text.index(signature)
    brace = text.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]

auto_flag_code = function(sl_source, "bool ApplyStreamlineAutoFlag(")
frame_check = function(sl_source, "bool Sl_Inputs_Dx12::IsCurrentConstantsFrame(")
frame_check = frame_check.replace("Sl_Inputs_Dx12::", "")
set_frame_count = function(ifg_source, "void IFGFeature::SetFrameCount(").replace("IFGFeature::", "")
constants_start = sl_source.index("        auto config = Config::Instance();", sl_source.index("bool Sl_Inputs_Dx12::setConstants"))
constants_end = sl_source.index("        // Frame data part", constants_start)
constants_prelude = sl_source[constants_start:constants_end]
assert "SaveXeFG" not in sl_source, "SL inference must not write learned flags to disk"

preamble = r'''
#include <cassert>
#include <concepts>
#include <cstdint>
#include <iostream>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include "IFGFeature_Reset.h"
using UINT64 = uint64_t;
#define LOG_TRACE(...) ((void)0)
namespace sl { enum Boolean { eFalse = 0, eTrue = 1, eInvalid = 2 }; }
'''
scaffold = r'''
enum class FGOutput { XeFG };
enum class FG_Flags { InvertedDepth = 1, JitteredMVs = 2, DisplayResolutionMVs = 4, Async = 8, InfiniteDepth = 16 };
struct Flags {
    int bits = 0;
    void reset() { bits = 0; }
    Flags& operator|=(FG_Flags f) { bits |= static_cast<int>(f); return *this; }
};
struct FG_Constants { Flags flags; unsigned displayWidth, displayHeight; };
struct Config {
    CustomOptional<bool> FGXeFGDepthInverted{true}, FGXeFGJitteredMV{false}, FGXeFGHighResMV{false};
    CustomOptional<bool> FGEnabled{true}, FGAsync{false};
    static Config* Instance() { static Config c; return &c; }
};
struct State {
    FGOutput activeFgOutput = FGOutput::XeFG;
    void* currentD3D12Device = nullptr;
    static State& Instance() { static State s; return s; }
};
struct Constants {
    sl::Boolean reset = sl::eInvalid, depthInverted = sl::eInvalid,
                motionVectorsJittered = sl::eInvalid, motionVectorsDilated = sl::eInvalid;
};
struct MockFG {
    FGHistoryResetLatch reset;
    bool active = true, paused = true;
    void RequestHistoryReset() { reset.Request(100); }
    void EvaluateState(void*, FG_Constants&) {}
    bool IsActive() { return active; }
    bool IsPaused() { return paused; }
    void Activate() { active = true; }
    uint64_t FrameCount() const { return 100; }
};
struct SlSubject {
    std::mutex _frameBoundaryMutex;
    uint32_t _currentFrameId = 100;
    bool reachedFrameData = false;
'''
tests = r'''
int main() {
    // A one-frame request survives arbitrarily many paused frames and SDK failures.
    FGHistoryResetLatch latch;
    assert(latch.PendingToken(100) == 0);
    latch.Request(100);
    assert(latch.PendingToken(99) == 0); // older dispatch cannot consume a new scene's reset
    const auto first = latch.PendingToken(100);
    assert(first != 0);
    for (int i = 0; i < 100; ++i) assert(latch.PendingToken(100) == first);
    // Failed dispatch has no acknowledgment, so the request survives.
    assert(latch.PendingToken(101) == first);
    latch.Acknowledge(first);
    assert(latch.PendingToken(101) == 0);
    // A request arriving during a successful dispatch must not be cleared by its old token.
    latch.Request(102);
    const auto old = latch.PendingToken(102);
    std::thread requestDuringDispatch([&] { latch.Request(103); });
    requestDuringDispatch.join();
    latch.Acknowledge(old);
    assert(latch.PendingToken(102) == 0);
    const auto latest = latch.PendingToken(103);
    assert(latest != 0 && latest != old);
    latch.Acknowledge(0);
    assert(latch.PendingToken(103) == latest);
    latch.Acknowledge(latest);
    assert(latch.PendingToken(104) == 0);

    // A downward game-frame rebase moves only an existing request. Its old
    // dispatch token must not acknowledge the rebased request.
    latch.RebasePending(0);
    assert(latch.PendingToken(1) == 0);

    CounterSubject counter;
    counter._frameCount = 100;
    counter._historyReset.Request(100);
    const auto counterToken = counter._historyReset.PendingToken(100);
    counter.SetFrameCount(0);
    assert(counter._frameCount == 0);
    const auto rebasedCounterToken = counter._historyReset.PendingToken(1);
    assert(rebasedCounterToken != 0 && rebasedCounterToken != counterToken);
    counter._historyReset.Acknowledge(counterToken);
    assert(counter._historyReset.PendingToken(1) == rebasedCounterToken);
    counter._historyReset.Acknowledge(rebasedCounterToken);
    counter.SetFrameCount(100);
    counter.SetFrameCount(1);
    assert(counter._historyReset.PendingToken(1) == 0);
    latch.Request(100);
    const auto beforeRebase = latch.PendingToken(100);
    latch.RebasePending(0);
    const auto afterRebase = latch.PendingToken(1);
    assert(afterRebase != 0 && afterRebase != beforeRebase);
    latch.Acknowledge(beforeRebase);
    assert(latch.PendingToken(1) == afterRebase);
    latch.RebasePending(1); // request already belongs to the new frame domain
    assert(latch.PendingToken(1) == afterRebase);
    latch.Acknowledge(afterRebase);
    assert(latch.PendingToken(2) == 0);
    latch.RebasePending(0);
    assert(latch.PendingToken(1) == 0);

    int metadataCases = 0;
    for (bool defaultValue : {false, true})
    for (int explicitChoice : {-1, 0, 1})
    for (auto value : {sl::eFalse, sl::eTrue, sl::eInvalid, static_cast<sl::Boolean>(9)})
    for (bool currentFrame : {false, true}) {
        CustomOptional<bool> option(defaultValue);
        if (explicitChoice >= 0) option.set_from_config(std::optional<bool>{explicitChoice != 0});
        const bool expected = explicitChoice >= 0 ? explicitChoice != 0 :
            currentFrame && (value == sl::eTrue || value == sl::eFalse) ? value == sl::eTrue : defaultValue;
        assert(ApplyStreamlineAutoFlag(option, value, currentFrame) == expected);
        assert(option.has_persistent_value() == (explicitChoice >= 0));
        assert(option.persistent_value().has_value() == (explicitChoice >= 0));
        if (explicitChoice >= 0) assert(option.persistent_value().value() == (explicitChoice != 0));
        if (explicitChoice < 0) assert(!option.value_for_config().has_value());
        ++metadataCases;
    }
    CustomOptional<bool> learned(false);
    assert(ApplyStreamlineAutoFlag(learned, sl::eTrue, true));
    assert(!learned.has_persistent_value());
    assert(!ApplyStreamlineAutoFlag(learned, sl::eFalse, true));
    assert(!ApplyStreamlineAutoFlag(learned, sl::eTrue, false));
    learned = true; // user changes the menu after auto-detection
    assert(ApplyStreamlineAutoFlag(learned, sl::eFalse, true));
    assert(learned.has_persistent_value());
    for (bool defaultValue : {false, true})
    for (bool explicitValue : {false, true}) {
        CustomOptional<bool> beforeSave(defaultValue);
        beforeSave.set_from_config(std::optional<bool>{explicitValue});
        beforeSave.set_volatile_value(!explicitValue);
        assert(beforeSave.has_persistent_value());
        assert(beforeSave.persistent_value() == std::optional<bool>{explicitValue});
        CustomOptional<bool> afterReload(defaultValue);
        afterReload.set_from_config(beforeSave.persistent_value());
        assert(afterReload.has_persistent_value());
        assert(ApplyStreamlineAutoFlag(afterReload, explicitValue ? sl::eFalse : sl::eTrue, true) == explicitValue);
    }

    // This executes the actual pre-EvaluateState/paused-return SL constants block.
    SlSubject sl;
    MockFG fg;
    assert(sl.IsCurrentConstantsFrame(0));
    assert(sl.IsCurrentConstantsFrame(100));
    assert(!sl.IsCurrentConstantsFrame(99));
    assert(!sl.IsCurrentConstantsFrame(101));
    Constants resetOnce;
    resetOnce.reset = sl::eTrue;
    assert(sl.Feed(fg, resetOnce, 100));
    assert(!sl.reachedFrameData);
    const auto pausedToken = fg.reset.PendingToken(100);
    assert(pausedToken != 0);
    Constants ordinary;
    ordinary.reset = sl::eFalse;
    for (int i = 0; i < 30; ++i) assert(sl.Feed(fg, ordinary, 100));
    assert(fg.reset.PendingToken(100) == pausedToken);
    fg.paused = false;
    assert(sl.Feed(fg, ordinary, 100));
    assert(sl.reachedFrameData);
    fg.reset.Acknowledge(pausedToken);
    assert(fg.reset.PendingToken(101) == 0);
    assert(sl.Feed(fg, resetOnce, 99)); // stale metadata cannot request a reset for the current frame
    assert(fg.reset.PendingToken(101) == 0);
    std::cout << "PASS: production reset latch, paused SL constants, stale-frame protection, "
              << metadataCases << " auto/explicit metadata cases\n";
}
'''
counter_subject = "struct CounterSubject { UINT64 _frameCount = 0; FGHistoryResetLatch _historyReset;\n" + set_frame_count + "\n};\n"
body = (preamble + counter_subject + optional_code + auto_flag_code + scaffold + frame_check +
        "\n bool Feed(MockFG& fg, Constants data, uint32_t frameId) {\n"
        " auto* fgOutput = &fg; bool infiniteDepth = false; reachedFrameData = false;\n" +
        constants_prelude.replace("const auto constantsInternalFrame", "[[maybe_unused]] const auto constantsInternalFrame") + "\n reachedFrameData = true; return true;\n }\n};\n" + tests)
with tempfile.TemporaryDirectory(prefix="xefg-history-") as folder:
    tmp = Path(folder)
    cpp = tmp / "history.cpp"
    cpp.write_text(body, encoding="utf-8")
    include_dir = root / "OptiScaler/framegen"
    exe = tmp / ("history.exe" if os.name == "nt" else "history")
    if os.name == "nt":
        subprocess.run(["cl", "/nologo", "/std:c++20", "/EHsc", "/W4", "/UNDEBUG", str(cpp),
                        "/I" + str(include_dir), "/Fe:" + str(exe)], cwd=tmp, check=True)
    else:
        compiler = shutil.which("c++") or shutil.which("clang++")
        subprocess.run([compiler, "-std=c++20", "-Wall", "-Wextra", "-Werror", "-pthread",
                        "-I", str(include_dir), str(cpp), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
