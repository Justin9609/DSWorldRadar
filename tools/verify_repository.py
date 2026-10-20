from pathlib import Path
import hashlib
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
manifest = {}
for line in (root / 'ROOT_SHA256SUMS.txt').read_text(encoding='utf-8').splitlines():
    digest, name = line.split('  ', 1)
    manifest[name] = digest
actual = {
    p.relative_to(root).as_posix()
    for p in root.rglob('*')
    if p.is_file()
    and p.relative_to(root).as_posix() != 'ROOT_SHA256SUMS.txt'
    and not any(part in {'.git', '__pycache__'} for part in p.relative_to(root).parts)
}
if set(manifest) != actual:
    raise SystemExit('Repository inventory differs from the prepared snapshot; use a clean checkout.')
for name, digest in manifest.items():
    if hashlib.sha256((root / name).read_bytes()).hexdigest() != digest:
        raise SystemExit('Checksum mismatch: ' + name)
subprocess.run([sys.executable, str(root / 'review/tools/verify_review_bundle.py')], check=True)
print('Verified repository snapshot:', len(manifest), 'files plus ROOT_SHA256SUMS.txt.')
