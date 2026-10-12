"""Check that relative links and image references in Markdown files resolve.

Broken relative links are the most common cosmetic defect in a published
repository and are easy to miss by eye. This walks every `.md` file in the
project and verifies that each relative link target exists on disk.

Handles:
  * `[text](path)` and `![alt](path)`
  * links with anchors: `docs/BUILD.md#section` -> checks `docs/BUILD.md`
  * links with a title: `[t](path "title")`
  * skips absolute URLs (http/https/mailto) and pure anchors (`#foo`)
  * warns when a `#anchor` does not match any heading in the target file
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except (AttributeError, ValueError):
    pass

ROOT = Path(__file__).resolve().parent.parent

# [text](target) — also matches images; target may carry a "title"
LINK_RE = re.compile(r"!?\[[^\]]*\]\(\s*([^)\s]+)(?:\s+\"[^\"]*\")?\s*\)")

# inline code spans must be removed before scanning, otherwise regex literals and
# tuples inside `code` look like links
INLINE_CODE_RE = re.compile(r"`[^`]*`")

SKIP_DIRS = {"node_modules", "oh_modules", ".git", "build", ".hvigor", ".idea"}
EXTERNAL_PREFIXES = ("http://", "https://", "mailto:", "tel:", "data:")


def scannable_lines(text: str) -> list[tuple[int, str]]:
    """Yield (line_number, line) for lines outside fenced code blocks,
    with inline code spans blanked out."""
    out: list[tuple[int, str]] = []
    in_fence = False
    fence_marker = ""
    for idx, line in enumerate(text.splitlines(), 1):
        stripped = line.lstrip()
        if not in_fence and (stripped.startswith("```") or stripped.startswith("~~~")):
            in_fence = True
            fence_marker = stripped[:3]
            continue
        if in_fence:
            if stripped.startswith(fence_marker):
                in_fence = False
            continue
        out.append((idx, INLINE_CODE_RE.sub("", line)))
    return out


def headings(path: Path) -> set[str]:
    """Collect GitHub-style anchors from a Markdown file's headings."""
    found: set[str] = set()
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.startswith("#"):
            continue
        text = line.lstrip("#").strip()
        if not text:
            continue
        # strip inline markup
        text = re.sub(r"[`*_\[\]()]", "", text).strip().lower()
        # GitHub keeps CJK, drops most punctuation, turns spaces into '-'
        anchor = re.sub(r"[^\w\u4e00-\u9fff\u3040-\u30ff-]+", "-", text).strip("-")
        if anchor:
            found.add(anchor)
    return found


def main() -> int:
    md_files = [
        p for p in ROOT.rglob("*.md")
        if not any(part in SKIP_DIRS for part in p.parts)
    ]
    if not md_files:
        print("no markdown files found", file=sys.stderr)
        return 2

    broken: list[str] = []
    anchor_warnings: list[str] = []
    checked = 0
    anchor_cache: dict[Path, set[str]] = {}

    for md in sorted(md_files):
        rel_md = md.relative_to(ROOT)
        for lineno, line in scannable_lines(md.read_text(encoding="utf-8", errors="replace")):
            for target in LINK_RE.findall(line):
                checked += 1
                if target.startswith(EXTERNAL_PREFIXES) or target.startswith("#"):
                    continue

                path_part, _, anchor = target.partition("#")
                if not path_part:
                    continue

                resolved = (md.parent / path_part).resolve()
                try:
                    exists = resolved.exists()
                except OSError:
                    exists = False

                if not exists:
                    broken.append(f"{rel_md}:{lineno}: 目标不存在 -> {target}")
                    continue

                if anchor and resolved.suffix == ".md" and resolved.is_file():
                    if resolved not in anchor_cache:
                        anchor_cache[resolved] = headings(resolved)
                    if anchor.lower() not in anchor_cache[resolved]:
                        anchor_warnings.append(
                            f"{rel_md}:{lineno}: 锚点可能失效 -> {target}"
                        )

    print(f"检查了 {len(md_files)} 个 Markdown 文件，{checked} 个链接")
    if broken:
        print(f"\n=== 断链 ({len(broken)}) ===")
        for b in broken:
            print("  " + b)
    if anchor_warnings:
        print(f"\n=== 锚点告警 ({len(anchor_warnings)}) ===")
        for w in anchor_warnings:
            print("  " + w)
    if not broken and not anchor_warnings:
        print("\n全部链接可解析")

    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
