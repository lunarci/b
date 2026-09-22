"""Exercise the production cap query across initialization and provider limits."""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).resolve() / 'OptiScaler'
text = (source / 'State.h').read_text(encoding='utf-8-sig')
start = text.index('inline int MaxInterpolationCountForGame(')
brace = text.index('{', start)
depth = 1
end = brace + 1
while depth:
    depth += (text[end] == '{') - (text[end] == '}')
    end += 1
production = text[start:end]
for file in ['NVNGX_Parameter.cpp', 'hooks/Streamline_Hooks.cpp']:
    body = (source / file).read_text(encoding='utf-8-sig')
    assert re.search(r'MaxInterpolationCountForGame\(\s*Config::Instance\(\)->FGXeFGMaxInterpolatedFrames.value_or_default\(\)\)', body), file

program = r'''
#include <cassert>
#include <iostream>
enum class FGOutput { NoFG, XeFG, FSRFG };
struct FG {
    int limit = 1;
    bool ready = false;
    void* FrameGenerationContext() { return ready ? this : nullptr; }
    int GetMaxInterpolationCount() const { return limit; }
};
struct State {
    FGOutput activeFgOutput = FGOutput::XeFG;
    FG* currentFG = nullptr;
    static State& Instance() { static State s; return s; }
};
''' + production + r'''
int main() {
    auto& s = State::Instance();
    assert(MaxInterpolationCountForGame(5) == 5); // six total, before an object exists
    FG fg;
    s.currentFG = &fg;
    assert(MaxInterpolationCountForGame(5) == 5); // ignore the uninitialized placeholder
    fg.ready = true;
    fg.limit = 5;
    assert(MaxInterpolationCountForGame(5) == 5); // initialized six-total provider
    fg.ready = false;
    assert(MaxInterpolationCountForGame(5) == 5); // recreate does not expose two or eight
    fg.ready = true;
    fg.limit = 7;
    assert(MaxInterpolationCountForGame(5) == 5); // configured allocation still wins
    fg.limit = 3;
    assert(MaxInterpolationCountForGame(5) == 3); // lower native capability is respected
    fg.limit = 1;
    assert(MaxInterpolationCountForGame(5) == 1); // failed unlock never advertises six
    fg.limit = 0;
    assert(MaxInterpolationCountForGame(5) == 1);
    fg.limit = 7;
    assert(MaxInterpolationCountForGame(0) == 1);
    assert(MaxInterpolationCountForGame(7) == 7); // implementation ceiling is not re-locked
    s.activeFgOutput = FGOutput::FSRFG;
    assert(MaxInterpolationCountForGame(5) == 1);
    s.activeFgOutput = FGOutput::NoFG;
    assert(MaxInterpolationCountForGame(5) == 1);
    std::cout << "PASS: 12 production capability scenarios and both game-query call sites\n";
}
'''
with tempfile.TemporaryDirectory(prefix='xefg-cap-') as folder:
    root = Path(folder)
    cpp = root / 'test.cpp'
    cpp.write_text(program, encoding='utf-8')
    binary = root / ('test.exe' if os.name == 'nt' else 'test')
    if os.name == 'nt':
        command = ['cl', '/nologo', '/EHsc', '/std:c++20', str(cpp), '/Fe:' + str(binary)]
    else:
        command = ['g++', '-std=c++20', '-O2', str(cpp), '-o', str(binary)]
    subprocess.run(command, cwd=root, check=True)
    subprocess.run([str(binary)], check=True)
