"""Check that every package carries one version, and print that version's changelog section.

    python3 scripts/check-versions.py 0.2.0            exit 1 if any package has another version
    python3 scripts/check-versions.py 0.2.0 --notes    also print the CHANGELOG section for 0.2.0

The release workflow runs this first, so a tag can never publish mismatched packages.
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def found(path: str, pattern: str, flags: int = re.M) -> str:
    match = re.search(pattern, read(path), flags)
    return match.group(1) if match else "(no version found)"


VERSIONS = {
    "packages/js/package.json": json.loads(read("packages/js/package.json"))["version"],
    "packages/python/pyproject.toml": found("packages/python/pyproject.toml", r'^version = "([^"]+)"'),
    "packages/python/regex_parity/__init__.py": found("packages/python/regex_parity/__init__.py", r'^__version__ = "([^"]+)"'),
    "packages/java/build.gradle": found("packages/java/build.gradle", r"^version = '([^']+)'"),
    "packages/rust/Cargo.toml": found("packages/rust/Cargo.toml", r'^version = "([^"]+)"'),
    "packages/dotnet/src/RegexParity/RegexParity.csproj": found("packages/dotnet/src/RegexParity/RegexParity.csproj", r"<Version>([^<]+)</Version>"),
    "packages/ruby/lib/regex_parity.rb": found("packages/ruby/lib/regex_parity.rb", r'VERSION = "([^"]+)"'),
}


def notes(version: str) -> str | None:
    lines = read("CHANGELOG.md").splitlines()
    for start, line in enumerate(lines):
        if line.startswith(f"## {version}"):
            end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
            return "\n".join(lines[start + 1 : end]).strip()
    return None


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    version = sys.argv[1]
    wrong = {path: v for path, v in VERSIONS.items() if v != version}
    section = notes(version)
    for path, v in wrong.items():
        print(f"{path}: {v}, not {version}", file=sys.stderr)
    if section is None:
        print(f"CHANGELOG.md has no '## {version}' section", file=sys.stderr)
    if wrong or section is None:
        return 1
    if "--notes" in sys.argv:
        print(section)
    else:
        print(f"every package is {version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
