#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
base="${1:-b75ac47afe03a78c809b0e3c91b87f790f1598b8}"
python3 - <<'PY'
from pathlib import Path
import re
pattern = re.compile(r'/(?:create-log|take-lease|commit|realm/read-capability)|realm_secret|write_secret|storageFetch')
def hits(directory):
    return sum(len(pattern.findall(p.read_text())) for p in Path(directory).rglob('*.ts'))
control = hits('src/realm')
subject = hits('backup')
print(f'A4 SOURCE baseline live-realm matches={control}; backup matches={subject}')
assert control > 0, 'source scanner is blind'
assert subject == 0, 'backup references a write surface'
PY
git diff --exit-code "$base" -- wrangler.jsonc src/index.ts ../commonplace_log/
echo "A6 PASS: live config, live entry module, and commonplace_log/ have zero diff from $base"
