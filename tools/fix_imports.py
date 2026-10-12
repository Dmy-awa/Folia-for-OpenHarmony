"""Repair relative import paths in the ArkTS sources.

For every relative import that does not resolve, try shifting the spec up by one
or more `../` levels and rewrite it only if exactly one candidate resolves.
Also lists files whose imports cannot be repaired, so they can be fixed by hand.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# Windows 控制台默认是 GBK，中文与符号会直接抛 UnicodeEncodeError
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except (AttributeError, ValueError):
    pass

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "entry" / "src" / "main" / "ets"

IMPORT_RE = re.compile(r"(from\s*['\"])(\.[^'\"]*)(['\"])")


def resolves(importer: Path, spec: str) -> Path | None:
    base = (importer.parent / spec).resolve()
    for candidate in (base.with_suffix(".ets"), base / "index.ets"):
        if candidate.exists():
            return candidate
    return None


def candidates_for(spec: str) -> list[str]:
    """Specs obtained by adding 1..4 extra `../` levels.

    Handles both `./x` (promote to `../x`, `../../x`, ...) and already-relative
    `../x` (extend to `../../x`, ...). The first entry is the smallest change,
    so a valid rewrite always moves the path up by as few levels as possible.
    """
    out: list[str] = []
    if spec.startswith("./"):
        tail = spec[2:]
        for extra in range(1, 5):
            out.append("../" * extra + tail)
        return out
    if spec.startswith("../"):
        depth = 0
        rest = spec
        while rest.startswith("../"):
            depth += 1
            rest = rest[3:]
        for extra in range(1, 5):
            out.append("../" * (depth + extra) + rest)
        return out
    return out


def main() -> int:
    changed: list[str] = []
    unresolved: list[str] = []

    for path in sorted(SRC.rglob("*.ets")):
        text = path.read_text(encoding="utf-8")
        original = text

        def replace(match: re.Match[str]) -> str:
            prefix, spec, suffix = match.group(1), match.group(2), match.group(3)
            if not spec.startswith("."):
                return match.group(0)
            if resolves(path, spec) is not None:
                return match.group(0)
            hits = [c for c in candidates_for(spec) if resolves(path, c) is not None]
            if len(hits) == 1:
                return f"{prefix}{hits[0]}{suffix}"
            return match.group(0)

        text = IMPORT_RE.sub(replace, text)
        if text != original:
            path.write_text(text, encoding="utf-8")
            changed.append(str(path.relative_to(ROOT)))

        # report anything still broken
        for match in IMPORT_RE.finditer(text):
            spec = match.group(2)
            if spec.startswith(".") and resolves(path, spec) is None:
                line_no = text.count("\n", 0, match.start()) + 1
                unresolved.append(f"{path.relative_to(ROOT)}:{line_no}: {spec}")

    print(f"rewrote imports in {len(changed)} file(s):")
    for c in changed:
        print("  " + c)

    if unresolved:
        print(f"\nSTILL UNRESOLVED ({len(unresolved)}):")
        for u in unresolved:
            print("  " + u)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
