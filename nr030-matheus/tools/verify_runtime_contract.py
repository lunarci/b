"""Read-only exact-C7 PE/ABI signature check. Does not load or execute the DLL."""
import argparse, hashlib, json, struct
from pathlib import Path
EXPECTED_SHA='c7aad08f555bb8a7650f084c3e35aa188587060754ba0ac6538a5152c0a9f2de'
EXPECTED_SIZE=7290880
HELPER_RVA, HELPER_END=0x1c430,0x1c9bc
HELPER_SHA='75a51d2ceb8731d5068a556f7d4e782710951b730ccfae582ecb114c7405c5d3'
def verify(path):
    data=Path(path).read_bytes()
    def u16(n): return struct.unpack_from('<H',data,n)[0]
    def u32(n): return struct.unpack_from('<I',data,n)[0]
    assert len(data)==EXPECTED_SIZE, 'Unexpected file size'
    assert hashlib.sha256(data).hexdigest()==EXPECTED_SHA, 'Unrecognized NR binary'
    assert data[:2]==b'MZ'
    pe=u32(0x3c)
    assert data[pe:pe+4]==b'PE\0\0' and u16(pe+4)==0x8664, 'Not x64 PE'
    optional=pe+24
    assert u16(optional)==0x20b and u32(optional+56)==0x700000
    sections=[]
    base=optional+u16(pe+20)
    for i in range(u16(pe+6)):
        o=base+i*40
        sections.append((u32(o+12),u32(o+8),u32(o+20),u32(o+16),u32(o+36)))
    def offset(rva,count=1):
        for va,vs,raw,rs,flags in sections:
            if va<=rva and rva+count<=va+min(vs,rs): return raw+rva-va
        raise ValueError('RVA is not fully file backed')
    assert any(va<=HELPER_RVA and HELPER_END<=va+vs and flags&0x20000000 for va,vs,raw,rs,flags in sections)
    start=offset(HELPER_RVA,HELPER_END-HELPER_RVA)
    helper=data[start:start+HELPER_END-HELPER_RVA]
    assert hashlib.sha256(helper).hexdigest()==HELPER_SHA, 'Helper bytes differ'
    relocRva=u32(optional+112+5*8); relocSize=u32(optional+112+5*8+4)
    collisions=[]
    if relocSize:
        pos=offset(relocRva,relocSize); end=pos+relocSize
        while pos<end:
            page,block=struct.unpack_from('<II',data,pos)
            assert block>=8 and pos+block<=end
            for ent in range(pos+8,pos+block,2):
                item=u16(ent); kind=item>>12; location=page+(item&4095)
                if kind and HELPER_RVA<=location<HELPER_END: collisions.append(location)
            pos+=block
    assert not collisions, 'Helper contains ASLR relocations'
    return dict(static_binary_contract_verified=True, runtime_validated=False,
                file_sha256=EXPECTED_SHA,file_size=EXPECTED_SIZE,
                helper_rva=hex(HELPER_RVA),helper_size=len(helper),helper_sha256=HELPER_SHA,
                helper_base_relocations=collisions,
                scope='Read-only PE/hash/signature check; no DLL loading, inference, GPU or game execution')
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dll');parser.add_argument('--json-output')
    args=parser.parse_args();result=verify(args.dll)
    text=json.dumps(result,indent=2)
    if args.json_output: Path(args.json_output).write_text(text+'\n',encoding='utf-8')
    print(text)
