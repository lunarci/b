"""Verify the compiled core and its matching PDB; never package stock runtimes."""
from pathlib import Path
import json
import os
import shutil
import struct
import sys
import uuid
import zipfile
from check_prepared import check
from prepare import KIT, NAME, canonical, digest


class PE:
    def __init__(self, data):
        self.data = data
        if data[:2] != b'MZ':
            raise ValueError('Missing DOS header.')
        pe = self.u32(0x3c)
        if data[pe:pe + 4] != b'PE\0\0':
            raise ValueError('Missing PE signature.')
        machine, count, _, _, _, size, flags = struct.unpack_from('<HHIIIHH', data, pe + 4)
        optional = pe + 24
        if machine != 0x8664 or not flags & 0x2000 or self.u16(optional) != 0x20b:
            raise ValueError('Expected an AMD64 PE32+ DLL.')
        if self.u32(optional + 108) < 7:
            raise ValueError('PE data directories missing.')
        self.directories = optional + 112
        self.header_size = self.u32(optional + 60)
        self.sections = []
        for i in range(count):
            p = optional + size + 40 * i
            vsize, va, rawsize, rawptr = struct.unpack_from('<IIII', data, p + 8)
            self.sections.append((va, max(vsize, rawsize), rawptr, rawsize))

    def u16(self, p):
        return struct.unpack_from('<H', self.data, p)[0]

    def u32(self, p):
        return struct.unpack_from('<I', self.data, p)[0]

    def offset(self, rva, size=1):
        if rva < self.header_size and rva + size <= len(self.data):
            return rva
        for va, extent, rawptr, rawsize in self.sections:
            if va <= rva and rva + size <= va + extent and rva - va + size <= rawsize:
                offset = rawptr + rva - va
                if offset + size <= len(self.data):
                    return offset
        raise ValueError(f'Invalid PE RVA {rva:#x}.')

    def directory(self, number):
        return struct.unpack_from('<II', self.data, self.directories + number * 8)

    def exports(self):
        rva, _ = self.directory(0)
        p = self.offset(rva, 40)
        functions = self.u32(p + 20)
        count = self.u32(p + 24)
        if not 3 <= count <= 100000 or not 3 <= functions <= 100000:
            raise ValueError('Invalid export table size.')
        addresses = self.offset(self.u32(p + 28), functions * 4)
        names = self.offset(self.u32(p + 32), count * 4)
        ordinals = self.offset(self.u32(p + 36), count * 2)
        found = set()
        for i in range(count):
            start = self.offset(self.u32(names + i * 4))
            end = self.data.find(b'\0', start, start + 4096)
            ordinal = self.u16(ordinals + i * 2)
            if end < 0 or ordinal >= functions:
                raise ValueError('Malformed named export.')
            name = self.data[start:end].decode('ascii')
            if self.u32(addresses + ordinal * 4) == 0:
                raise ValueError(f'Null export: {name}')
            found.add(name)
        return found

    def codeview(self):
        rva, size = self.directory(6)
        if not rva or size % 28:
            raise ValueError('Missing PE debug directory.')
        p = self.offset(rva, size)
        records = []
        for i in range(size // 28):
            entry = p + i * 28
            kind = self.u32(entry + 12)
            length = self.u32(entry + 16)
            pointer = self.u32(entry + 24)
            if kind == 2 and length >= 24 and self.data[pointer:pointer + 4] == b'RSDS':
                if pointer + length > len(self.data):
                    raise ValueError('Truncated CodeView record.')
                records.append((self.data[pointer + 4:pointer + 20], self.u32(pointer + 20)))
        if len(records) != 1:
            raise ValueError('Expected exactly one RSDS debug identity.')
        return records[0]


def pdb_identity(data):
    magic = b'Microsoft C/C++ MSF 7.00\r\n\x1aDS\0\0\0'
    if data[:32] != magic:
        raise ValueError('Not a real MSVC program database.')
    block, _, blocks, directory_size, _, block_map = struct.unpack_from('<IIIIII', data, 32)
    if block not in (512, 1024, 2048, 4096, 8192) or blocks * block > len(data):
        raise ValueError('Invalid PDB superblock.')
    count = (directory_size + block - 1) // block
    if count * 4 > block:
        raise ValueError('Unsupported oversized PDB directory map.')
    ids = struct.unpack_from('<' + 'I' * count, data, block_map * block)
    if any(i >= blocks for i in ids):
        raise ValueError('Invalid PDB directory block.')
    directory = b''.join(data[i * block:(i + 1) * block] for i in ids)[:directory_size]
    streams = struct.unpack_from('<I', directory, 0)[0]
    if streams < 2 or streams > 100000:
        raise ValueError('Missing PDB identity stream.')
    sizes = struct.unpack_from('<' + 'I' * streams, directory, 4)
    position = 4 + streams * 4
    identity = None
    for i, length in enumerate(sizes):
        pages = 0 if length == 0xffffffff else (length + block - 1) // block
        ids = struct.unpack_from('<' + 'I' * pages, directory, position)
        position += pages * 4
        if any(n >= blocks for n in ids):
            raise ValueError('Invalid PDB stream block.')
        if i == 1:
            stream = b''.join(data[n * block:(n + 1) * block] for n in ids)[:length]
            if len(stream) < 28:
                raise ValueError('Truncated PDB identity stream.')
            age = struct.unpack_from('<I', stream, 8)[0]
            identity = (stream[12:28], age)
            break
    return identity


def package(source, out):
    source, out = source.resolve(), out.resolve()
    prepared = check(source)
    tests_path = source / 'JAEYUN_TEST_RESULTS.json'
    tests = json.loads(tests_path.read_text(encoding='utf-8'))
    if tests.get('passed') is not True or not tests.get('tests'):
        raise ValueError('Regression suite result is missing, empty, or failed.')
    dll = source / 'x64/Release/a/OptiScaler.dll'
    pdb = source / 'x64/Release/OptiScaler.pdb'
    data = dll.read_bytes()
    pe = PE(data)
    exports = pe.exports()
    needed = {'CreateDXGIFactory', 'CreateDXGIFactory1', 'CreateDXGIFactory2'}
    if not needed <= exports:
        raise ValueError('DXGI proxy exports are missing.')
    marker = prepared['marker']
    if marker.encode('utf-16-le') not in data:
        raise ValueError('Build identity missing from PE version resource.')
    if pe.codeview() != pdb_identity(pdb.read_bytes()):
        raise ValueError('PDB GUID/age do not match the compiled DLL.')
    if out.exists() and any(out.iterdir()):
        raise ValueError('Refusing a nonempty output directory.')
    out.mkdir(parents=True, exist_ok=True)
    (out / 'core').mkdir()
    (out / 'symbols').mkdir()
    shutil.copy2(dll, out / 'core/OptiScaler.dll')
    shutil.copy2(pdb, out / 'symbols/OptiScaler.pdb')
    shutil.copy2(source / 'LICENSE', out / 'LICENSE_OptiScaler.txt')
    shutil.copy2(KIT / 'README_KO.md', out / 'README_KO.md')
    shutil.copy2(tests_path, out / 'TEST_RESULTS.json')
    evidence_zip = out / 'SOURCE_EVIDENCE.zip'
    with zipfile.ZipFile(evidence_zip, 'w', zipfile.ZIP_DEFLATED) as z:
        for file in sorted(KIT.rglob('*')):
            if file.is_file() and '__pycache__' not in file.parts and file.suffix != '.pyc':
                z.write(file, 'harness/' + file.relative_to(KIT).as_posix())
        z.write(KIT.parent / '.github/workflows/build-optiscaler-xefg.yml', 'harness/workflow.yml')
        z.write(source / 'JAEYUN_PREPARED.json', 'JAEYUN_PREPARED.json')
        z.write(tests_path, 'TEST_RESULTS.json')
        z.write(source / 'LICENSE', 'LICENSE_OptiScaler.txt')
        for name in prepared['prepared_files']:
            z.write(source / name, 'prepared-source/' + name)
    with zipfile.ZipFile(evidence_zip) as z:
        if z.testzip() is not None:
            raise ValueError('Source evidence ZIP failed verification.')
    guid, age = pe.codeview()
    manifest = {
        'schema_version': 1,
        'name': NAME,
        'marker': marker,
        'builder_commit': prepared['builder_commit'],
        'source': prepared['source'],
        'prepared_files': prepared['prepared_files'],
        'submodules': prepared['submodules'],
        'workflow_run': os.environ.get('GITHUB_RUN_ID'),
        'workflow_attempt': os.environ.get('GITHUB_RUN_ATTEMPT'),
        'windows_release_build_succeeded': True,
        'regression_tests_passed': True,
        'game_runtime_tested': False,
        'amd_gpu_tested': False,
        'package_scope': 'Core DLL and matching symbols only. Final runtime/settings are assembled from the supplied baseline separately.',
        'pe': {'machine': 'AMD64', 'format': 'PE32+', 'export_count': len(exports),
               'required_exports': sorted(needed), 'pdb_guid': str(uuid.UUID(bytes_le=guid)), 'pdb_age': age},
        'files': {file.relative_to(out).as_posix(): {'sha256': digest(file.read_bytes()), 'bytes': file.stat().st_size}
                  for file in sorted(out.rglob('*')) if file.is_file()},
    }
    (out / 'BUILD.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(f'Verified {marker}: AMD64 DXGI DLL; PDB GUID/age match; source regression gates passed.')


if __name__ == '__main__':
    package(Path(sys.argv[1]), Path(sys.argv[2]))
