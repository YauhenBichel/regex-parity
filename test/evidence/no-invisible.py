"""Fail when a file in test/evidence holds a raw invisible character.

They must be written as \\u escapes. They were once pasted in raw, which left a file claiming
"escapes so invisible characters stay visible" holding exactly what it said it did not.
"""

import pathlib
import sys

INVISIBLE = {0x00AD, 0x180E, 0xFEFF, 0x2028, 0x2029, *range(0x200B, 0x2010), *range(0x202A, 0x202F), *range(0x2060, 0x2065)}

found = [
    f"{path.name}:{number}: U+{ord(character):04X}"
    for path in sorted(pathlib.Path(sys.argv[1]).iterdir())
    if path.is_file()
    for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1)
    for character in line
    if ord(character) in INVISIBLE
]
if found:
    print("evidence: raw invisible characters; write them as \\u escapes:\n  " + "\n  ".join(found), file=sys.stderr)
    sys.exit(1)
