#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
scratch = root / ".test-doc-bash-fences"
if scratch.exists():
    for path in sorted(scratch.rglob("*"), reverse=True):
        if path.is_file():
            path.unlink()
        else:
            path.rmdir()
    scratch.rmdir()
scratch.mkdir()

documents = [
    root / "README.md",
    root / "docs/01-prerequisites.md",
    root / "docs/02-azure-foundation.md",
    root / "docs/03-install-dual-vn2.md",
    root / "docs/04-baseline-ondemand-benchmark.md",
    root / "docs/05-standby-cache-benchmark.md",
    root / "docs/06-analyze-results.md",
    root / "docs/07-limitations-troubleshooting-cleanup.md",
]

pattern = re.compile(r"```bash\n(.*?)```", re.S)
try:
    for doc in documents:
        text = doc.read_text(encoding="utf-8")
        blocks = pattern.findall(text)
        if not blocks:
            raise SystemExit(f"{doc.relative_to(root).as_posix()} must contain at least one bash fence")
        for index, block in enumerate(blocks, start=1):
            candidate = scratch / f"{doc.stem}-{index}.sh"
            candidate.write_text("#!/usr/bin/env bash\n" + block + "\n", encoding="utf-8")
            subprocess.run(["bash", "-n", str(candidate)], check=True, cwd=root)
finally:
    if scratch.exists():
        for path in sorted(scratch.rglob("*"), reverse=True):
            if path.is_file():
                path.unlink()
            else:
                path.rmdir()
        scratch.rmdir()

print("All documented bash fences pass bash -n independently.")
PY
