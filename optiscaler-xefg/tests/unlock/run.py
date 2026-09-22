from pathlib import Path
import subprocess, shutil, tempfile, struct, json, sys, os, argparse

parser=argparse.ArgumentParser(description='XeFG production-header patch safety checks with mocked Windows calls')
parser.add_argument('source_dir',type=Path)
parser.add_argument('--runtime-dir',type=Path)
args=parser.parse_args()
root=args.source_dir/'OptiScaler'/'proxies'
tmp=Path(tempfile.mkdtemp(prefix='xefg-safety-'))
for name in ('XeFGUnlock.h','XeLLUnLock.h','XeFGPacing.h'):
    shutil.copy2(root/name,tmp/name)
if os.name != 'nt':
    # MSVC's standard library also includes intrin.h; do not shadow its real
    # SIMD declarations on Windows. Linux only needs this stand-in intrinsic.
    (tmp/'intrin.h').write_text('''#pragma once
inline void* _ReturnAddress(){return nullptr;}
''')
(tmp/'Logger.h').write_text('#pragma once\n#define LOG_INFO(...) ((void)0)\n#define LOG_WARN(...) ((void)0)\n#define LOG_ERROR(...) ((void)0)\n')
(tmp/'Config.h').write_text('''#pragma once
template<class T> struct Opt { T value; T value_or_default() const {return value;} };
struct Config {
 static constexpr int XeFGMaxInterpolations=7;
 Opt<bool> FGXeFGUnlockEnabled{true}, FGXeFGExtraPacing{true};
 Opt<int> FGXeFGMaxInterpolatedFrames{5};
 static Config* Instance(){static Config c;return &c;}
};
''')
(tmp/'SysUtils.h').write_text('''#pragma once
#include <cstdint>
#include <cstring>
#include <string>
#include <algorithm>
#include <vector>
#include <cassert>
#include <iostream>
using HMODULE=void*; using DWORD=uint32_t; using WORD=uint16_t;
struct LARGE_INTEGER { int64_t QuadPart; };
struct IMAGE_DOS_HEADER { uint16_t e_magic; int32_t e_lfanew; };
struct IMAGE_FILE_HEADER { uint32_t TimeDateStamp; uint16_t NumberOfSections; };
struct IMAGE_OPTIONAL_HEADER { uint32_t SizeOfImage; };
struct IMAGE_NT_HEADERS { uint32_t Signature; IMAGE_FILE_HEADER FileHeader; IMAGE_OPTIONAL_HEADER OptionalHeader; };
struct IMAGE_SECTION_HEADER { uint8_t Name[8]; uint32_t VirtualAddress; union { uint32_t VirtualSize; } Misc; };
#define IMAGE_FIRST_SECTION(nt) reinterpret_cast<IMAGE_SECTION_HEADER*>((nt)+1)
constexpr uint16_t IMAGE_DOS_SIGNATURE=0x5a4d;
constexpr uint32_t IMAGE_NT_SIGNATURE=0x4550, IMAGE_SIZEOF_SHORT_NAME=8, PAGE_EXECUTE_READWRITE=0x40;
inline int writeRequests=0,failRequest=0,flushCount=0,corruptFlush=0;
inline bool VirtualProtect(void*,size_t,DWORD protection,DWORD* old) {
 *old=0x20;
 if(protection==PAGE_EXECUTE_READWRITE && ++writeRequests==failRequest)return false;
 return true;
}
inline bool FlushInstructionCache(void*,void* ptr,size_t) {
 if(++flushCount==corruptFlush)reinterpret_cast<uint8_t*>(ptr)[0]^=0xff;
 return true;
}
inline void* GetCurrentProcess(){return nullptr;}
inline void QueryPerformanceFrequency(LARGE_INTEGER* x){x->QuadPart=1000000;}
inline void QueryPerformanceCounter(LARGE_INTEGER* x){static int64_t t=0;x->QuadPart=++t;}
inline void Sleep(int){} inline void YieldProcessor(){}
''')
(tmp/'test.cpp').write_text('''#include "XeFGUnlock.h"
#include "XeLLUnLock.h"
std::vector<uint8_t> image(bool xell=false){
 std::vector<uint8_t> b(xell?0x6a000:0x15ed000);
 auto* dos=reinterpret_cast<IMAGE_DOS_HEADER*>(b.data());dos->e_magic=IMAGE_DOS_SIGNATURE;dos->e_lfanew=128;
 auto* nt=reinterpret_cast<IMAGE_NT_HEADERS*>(b.data()+128);nt->Signature=IMAGE_NT_SIGNATURE;
 nt->FileHeader.TimeDateStamp=xell?0x6a561284:0x69cb0f4d;nt->FileHeader.NumberOfSections=1;
 nt->OptionalHeader.SizeOfImage=b.size();auto* s=IMAGE_FIRST_SECTION(nt);
 memcpy(s->Name,".text",5);s->VirtualAddress=0x1000;s->Misc.VirtualSize=b.size()-0x1000;
 auto put=[&](size_t r,std::initializer_list<uint8_t> v){std::copy(v.begin(),v.end(),b.begin()+r);};
 if(xell){put(0xd1c9,{0x83,0xfb,3,0x76,7});return b;}
 put(0x20da4f,{0x0f,0x85,0xcc,0,0,0});put(0x1a5de4,{0x74,9});put(0x1a517d,{0xbb,3,0,0,0});
 put(0x1a45c2,{0xc7,0x87,0x6c,1,0,0,1,0,0,0});put(0x20973b,{0xb8,1,0,0,0});
 memcpy(b.data()+XeFGPacing::PresentThunkRva,XeFGPacing::PresentThunkExpected,16);
 memcpy(b.data()+XeFGPacing::SchedThunkRva,XeFGPacing::SchedThunkExpected,16);
 memcpy(b.data()+XeFGPacing::TimestampThunkRva,XeFGPacing::TimestampThunkExpected,16);
 return b;
}
int main(int argc,char**argv){
 std::string mode=argv[1];bool ll=mode.rfind("xell",0)==0;auto b=image(ll);
 if(mode=="unknown" || mode=="xell_unknown")reinterpret_cast<IMAGE_NT_HEADERS*>(b.data()+128)->FileHeader.TimeDateStamp++;
 if(mode=="mismatch")b[0x20973b]^=1;
 if(mode=="pacing_mismatch")b[XeFGPacing::TimestampThunkRva]^=1;
 if(mode=="write_fail")failRequest=3;
 if(mode=="partial_write")corruptFlush=3;
 if(mode=="pacing_write_fail")failRequest=7;
 if(mode=="pacing_partial_write")corruptFlush=8;
 if(mode=="xell_partial_write")corruptFlush=1;
 auto original=b;bool ok=ll?XeLLUnlock::Apply(b.data()):XeFGUnlock::Apply(b.data());
 if(mode=="success"){
  assert(ok && XeFGUnlock::Applied() && XeFGPacing::g_enabled);
  assert(b[0x1a517e]==5 && b[0x20973c]==5);
  assert(b[XeFGPacing::PresentThunkRva]==0xff);
 }else if(mode=="xell_success"){
  assert(ok && XeLLUnlock::Applied() && b[0xd1cb]==5);
 }else{
  assert(!ok && b==original);
  if(!ll)assert(!XeFGUnlock::Applied() && !XeFGPacing::g_enabled);
  if(mode=="unknown" || mode=="mismatch" || mode=="xell_unknown")assert(writeRequests==0);
 }
 std::cout<<mode<<": PASS\\n";
}
''')
binary=tmp/('test.exe' if os.name=='nt' else 'test')
if os.name=='nt':
    command=['cl','/nologo','/std:c++20','/EHsc','/I'+str(tmp),str(tmp/'test.cpp'),'/Fe:'+str(binary)]
else:
    # Match the donor's MSVC function-pointer-to-void* extension in this Linux mock.
    command=['g++','-std=c++20','-fpermissive','-w','-O0','-I',str(tmp),str(tmp/'test.cpp'),'-o',str(binary)]
subprocess.run(command,cwd=tmp,check=True)
cases=['unknown','mismatch','write_fail','partial_write','pacing_mismatch','pacing_write_fail','pacing_partial_write','success','xell_unknown','xell_partial_write','xell_success']
for case in cases:subprocess.run([str(binary),case],check=True)

path=args.runtime_dir or args.source_dir/'external'/'xess'/'bin'
def pe_bytes(name,rva,count,stamp,size):
 data=(path/name).read_bytes();off=struct.unpack_from('<I',data,0x3c)[0]
 assert struct.unpack_from('<I',data,off+8)[0]==stamp
 assert struct.unpack_from('<I',data,off+24+56)[0]==size
 n=struct.unpack_from('<H',data,off+6)[0];opt=struct.unpack_from('<H',data,off+20)[0]
 for k in range(n):
  s=off+24+opt+40*k;vs,va,rs,rp=struct.unpack_from('<IIII',data,s+8)
  if va<=rva<va+max(vs,rs):return data[rp+rva-va:rp+rva-va+count]
 raise ValueError(rva)
fg_sites={0x20da4f:'0f85cc000000',0x1a5de4:'7409',0x1a517d:'bb03000000',0x1a45c2:'c7876c01000001000000',0x20973b:'b801000000',0x25c0:'e96bd12100'+'cc'*11,0x3100:'e92bbd2100'+'cc'*11,0x3430:'e9fb162200'+'cc'*11}
for rva,h in fg_sites.items():assert pe_bytes('libxess_fg.dll',rva,len(bytes.fromhex(h)),0x69cb0f4d,0x15ed000)==bytes.fromhex(h)
try:
    assert pe_bytes('libxell.dll',0xd1c9,5,0x6a561284,0x6a000)==bytes.fromhex('83fb037607')
except AssertionError:
    assert pe_bytes('libxell.dll',0xced9,5,0x69a6c659,0x69000)==bytes.fromhex('83fb037607')
print('Packaged Intel binaries: PE identities and all9 expected patch/thunk sites PASS')
print('Scope: mocked Windows patch control flow and real binary bytes; no GPU/runtime performance claim.')
