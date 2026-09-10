"""Apply the reviewed patch only to the exact audited upstream revision."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys

kit = Path(__file__).resolve().parent
source = Path(sys.argv[1]).resolve()
spec = json.loads((kit / 'SOURCE.json').read_text())
head = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
if head != spec['commit']:
    raise SystemExit(f'Unexpected upstream revision: {head}')
target = source / spec['source_file']
canonical = target.read_bytes().replace(b'\r\n', b'\n')
if hashlib.sha256(canonical).hexdigest() != spec['base_sha256']:
    raise SystemExit('The source file does not match the reviewed input.')
target.write_bytes(canonical)
patch = str(kit / 'hudless-current-frame.patch')
subprocess.run(['git', '-C', str(source), 'apply', '--check', patch], check=True)
subprocess.run(['git', '-C', str(source), 'apply', patch], check=True)
patched = target.read_bytes().replace(b'\r\n', b'\n')
if hashlib.sha256(patched).hexdigest() != spec['patched_sha256']:
    raise SystemExit('Patched source hash mismatch.')
target.write_bytes(patched)
version = source / 'OptiScaler/resource.h'
data = version.read_text(encoding='utf-8')
old = '#define VER_PRODUCT_NAME "OptiScaler v" VER_PRODUCT_VERSION_STR'
if data.count(old) != 1:
    raise SystemExit('Unexpected version label format.')
version.write_text(data.replace(old, old + ' " [HUDResource-RC1]"'), encoding='utf-8', newline='\n')
subprocess.run(['git', '-C', str(source), 'diff', '--check'], check=True)
print('Applied HUD resource selection/state correction: HUDResource-RC1')
