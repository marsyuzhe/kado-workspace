"""Generate synthetic, reproducible QA inputs. Never reads user data."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[1]
out = root / 'artifacts/qa/v24-hash'
out.mkdir(parents=True, exist_ok=True)
data = bytearray(bytes(range(256)) * 65536)
rows = []
for name, changed in [('original.bin', False), ('one-byte-change.bin', True)]:
    if changed:
        data[8388608] ^= 1
    path = out / name
    if not path.exists():
        path.write_bytes(data)
    if path.read_bytes() != data:
        raise RuntimeError('Existing QA input changed; refusing overwrite')
    rows.append(dict(path=str(path), size=len(data), sha256=hashlib.sha256(data).hexdigest(), sha512=hashlib.sha512(data).hexdigest()))
(out / 'expected.json').write_text(json.dumps(rows, indent=2), encoding='utf-8')
logs = root / 'artifacts/qa/v24-logs'
logs.mkdir(parents=True, exist_ok=True)
large = logs / 'large.log'
if not large.exists():
    with large.open('wb') as stream:
        for start in range(0, 1800000, 10000):
            stream.write(''.join(f'2026-10-26T12:00:00Z {"ERROR" if i % 1000 == 0 else "INFO"} row={i} ' + 'x' * 96 + '\n' for i in range(start, start + 10000)).encode())
print(f'Owned synthetic log: {large.stat().st_size} bytes; two independent hashlib manifests ready.')
