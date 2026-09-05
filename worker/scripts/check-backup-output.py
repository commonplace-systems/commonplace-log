#!/usr/bin/env python3
"""Integrity gate for the reviewed production output paths; not a dataflow proof."""
import argparse
import hashlib
import json
from pathlib import Path

worker = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--backup-dir', type=Path, default=worker / 'backup')
args = parser.parse_args()
review = json.loads((worker / 'scripts/backup-output-review.json').read_text())
expected = review['sha256']
actual = {}
errors = []
for path in args.backup_dir.rglob('*'):
    name = path.relative_to(args.backup_dir).as_posix()
    if path.is_symlink():
        errors.append(f'symlink is unreviewed: {name}')
    elif path.is_file() and path.suffix != '.md':
        actual[name] = hashlib.sha256(path.read_bytes()).hexdigest()
for name in sorted(set(expected) | set(actual)):
    if expected.get(name) != actual.get(name):
        errors.append(f'unreviewed source or missing module: {name}')
print('D4 covers the complete production backup source set; excludes tests, fixture artifacts, operator exports and provider telemetry.')
if errors:
    for error in errors:
        print('D4 FAIL:', error)
    print('An output path may have changed. Before updating hashes, review every output: only realm READ requests and R2 writes are allowed; scheduled errors may include only fixed codes and an opaque run ID. No manifest, inventory or run payload to console, HTTP responses, external requests or extra bindings. Do not refresh hashes merely to clear this gate.')
    raise SystemExit(1)
print(f'D4 PASS: {len(actual)} production modules match the reviewed bucket-only artifact output paths.')
