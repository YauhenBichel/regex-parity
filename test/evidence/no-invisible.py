"""Fail when a file holds a raw invisible character. They must be written as escapes or code points.

    python3 test/evidence/no-invisible.py [path ...]      default: the directory of this script

They were once pasted in raw, which left a file claiming "escapes so invisible characters stay
visible" holding exactly what it said it did not.
"""

import pathlib
import sys

INVISIBLE = {0x000B, 0x00AD, 0x180E, 0xFEFF, 0x2028, 0x2029, *range(0x200B, 0x2010), *range(0x202A, 0x202F), *range(0x2060, 0x2065)}
SKIP = {"node_modules", "build", ".gradle", "__pycache__", "dist", "_site"}

roots = [pathlib.Path(p) for p in sys.argv[1:]] or [pathlib.Path(__file__).parent]
found = []
for root in roots:
    files = [root] if root.is_file() else sorted(p for p in root.rglob("*") if p.is_file() and not SKIP & set(p.parts))
    for path in files:
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for number, line in enumerate(text.splitlines(), 1):
            found += [f"{path}:{number}: U+{ord(c):04X}" for c in line if ord(c) in INVISIBLE]
if found:
    print("raw invisible characters; write them as escapes or code points:\n  " + "\n  ".join(found), file=sys.stderr)
    sys.exit(1)
