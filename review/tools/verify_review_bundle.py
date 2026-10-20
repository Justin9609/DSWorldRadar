from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parents[1]
manifest={}
for line in (root/'SHA256SUMS.txt').read_text(encoding='utf-8').splitlines():
    digest,name=line.split('  ',1)
    manifest[name]=digest
actual={p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file() and p.name!='SHA256SUMS.txt'}
assert set(manifest)==actual, 'Manifest inventory mismatch; use a clean extraction.'
for name,digest in manifest.items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest()==digest,name
mapping=json.loads((root/'SOURCE_BINARY_MAP.json').read_text(encoding='utf-8'))
for row in mapping['runtime_sources']:
    a=(root/row['source']).read_bytes()
    assert a==(root/row['runtime_reference']).read_bytes(),row['source']
    assert hashlib.sha256(a).hexdigest()==row['sha256'],row['source']
for row in mapping['native_components']:
    assert hashlib.sha256((root/row['path']).read_bytes()).hexdigest()==row['sha256'],row['path']
assert sum(not row['source_available'] for row in mapping['native_components'])==4
print('Verified',len(manifest),'files; eight exact runtime source mappings; five native binary hashes; four explicit native source gaps.')
