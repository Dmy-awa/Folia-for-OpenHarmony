"""Static sanity checks for the Folia HarmonyOS ArkTS project.

Not a compiler: it catches the mechanical mistakes that would otherwise cost a
round-trip in DevEco Studio.

Checks
  1. every relative import resolves to a file that exists
  2. no banned constructs that ArkTS rejects (comments stripped first)
  3. every named import is actually exported by the target module
  4. class fields (not interface members) have an initializer
  5. required config files exist and main_pages.json points at real pages
"""

from __future__ import annotations

import json
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

BANNED = [
    (re.compile(r"\brequire\s*\("), "require() is not available in ArkTS"),
    (re.compile(r":\s*any\b"), "`: any` is not allowed in ArkTS"),
    (re.compile(r"\bas\s+any\b"), "`as any` is not allowed in ArkTS"),
    (re.compile(r"\bObject\.assign\b"), "Object.assign is not supported in ArkTS"),
    (re.compile(r"\.\.\.\w+\s*[,}]"), "object spread is not supported in ArkTS"),
    (re.compile(r"\bconsole\.(log|info|warn|error)\b"), "use Logger instead of console.*"),
    (re.compile(r"\bdocument\."), "DOM globals are not available in ArkTS"),
    (re.compile(r"\bnavigator\."), "DOM globals are not available in ArkTS"),
    (re.compile(r"\blocalStorage\b"), "localStorage is not available in ArkTS"),
    (re.compile(r"\bwindow\.localStorage\b"), "localStorage is not available in ArkTS"),
    (re.compile(r"\bESObject\b"), "ESObject escape hatch"),
    # V1 decorators must not appear in a V2 codebase
    (re.compile(r"@State\b"), "state management V1 (@State) in a V2 codebase"),
    (re.compile(r"@Prop\b"), "state management V1 (@Prop) in a V2 codebase"),
    (re.compile(r"@Link\b"), "state management V1 (@Link) in a V2 codebase"),
    (re.compile(r"@ObjectLink\b"), "state management V1 (@ObjectLink) in a V2 codebase"),
]

IMPORT_RE = re.compile(
    r"^\s*import\s+(?:type\s+)?\{([^}]*)\}\s*from\s*['\"]([^'\"]+)['\"]",
    re.MULTILINE,
)
EXPORT_RE = re.compile(
    r"^\s*export\s+(?:declare\s+)?(?:abstract\s+)?(?:default\s+)?(?:async\s+)?"
    r"(?:const|let|var|function|class|interface|type|enum|struct)\s+([A-Za-z_$][\w$]*)",
    re.MULTILINE,
)
EXPORT_LIST_RE = re.compile(r"^\s*export\s*\{([^}]*)\}", re.MULTILINE)

# a class field with a type but no initializer and no decorator
FIELD_NO_INIT_RE = re.compile(
    r"^\s{2,}(?:private\s+|public\s+|protected\s+|readonly\s+|static\s+)*"
    r"([A-Za-z_$][\w$]*)\s*:\s*([^=;()]+);\s*$"
)
CLASS_OPEN_RE = re.compile(r"^\s*(?:export\s+)?(?:default\s+)?class\s+")
INTERFACE_OPEN_RE = re.compile(r"^\s*(?:export\s+)?(?:declare\s+)?(?:interface|type)\s+")


def strip_block_comments(text: str) -> str:
    """Replace /* ... */ with spaces, preserving line count and column offsets."""
    out = []
    i = 0
    in_block = False
    while i < len(text):
        if not in_block and text.startswith("/*", i):
            in_block = True
            out.append("  ")
            i += 2
            continue
        if in_block and text.startswith("*/", i):
            in_block = False
            out.append("  ")
            i += 2
            continue
        ch = text[i]
        if in_block:
            out.append("\n" if ch == "\n" else " ")
        else:
            out.append(ch)
        i += 1
    return "".join(out)


def strip_comments(text: str) -> str:
    """Strip block comments and // line comments, preserving offsets."""
    text = strip_block_comments(text)
    lines = []
    for line in text.split("\n"):
        idx = line.find("//")
        if idx >= 0:
            line = line[:idx] + " " * (len(line) - idx)
        lines.append(line)
    return "\n".join(lines)


def resolve_import(importer: Path, spec: str) -> Path | None:
    if not spec.startswith("."):
        return None
    base = (importer.parent / spec).resolve()
    for candidate in (base.with_suffix(".ets"), base / "index.ets"):
        if candidate.exists():
            return candidate
    return None


def module_exports(path: Path) -> set[str]:
    text = strip_comments(path.read_text(encoding="utf-8", errors="replace"))
    names = set(EXPORT_RE.findall(text))
    for group in EXPORT_LIST_RE.findall(text):
        for part in group.split(","):
            part = part.strip()
            if not part:
                continue
            if " as " in part:
                part = part.split(" as ")[-1].strip()
            names.add(part)
    return names


def main() -> int:
    errors: list[str] = []
    warnings: list[str] = []
    files = sorted(SRC.rglob("*.ets"))
    if not files:
        print("no source files found", file=sys.stderr)
        return 1

    export_cache: dict[Path, set[str]] = {}

    for path in files:
        rel = path.relative_to(ROOT)
        raw = path.read_text(encoding="utf-8", errors="replace")
        code = strip_comments(raw)
        code_lines = code.split("\n")

        # 2. banned constructs (on comment-stripped source)
        for pattern, message in BANNED:
            for match in pattern.finditer(code):
                line_no = code.count("\n", 0, match.start()) + 1
                snippet = code_lines[line_no - 1].strip()[:110]
                errors.append(f"{rel}:{line_no}: {message}  ->  {snippet}")

        # 1 + 3. imports
        for match in IMPORT_RE.finditer(code):
            names_raw, spec = match.group(1), match.group(2)
            target = resolve_import(path, spec)
            if target is None:
                if spec.startswith("."):
                    line_no = code.count("\n", 0, match.start()) + 1
                    errors.append(f"{rel}:{line_no}: unresolved import '{spec}'")
                continue
            if target not in export_cache:
                export_cache[target] = module_exports(target)
            available = export_cache[target]
            for name in names_raw.split(","):
                name = name.strip()
                if not name:
                    continue
                if " as " in name:
                    name = name.split(" as ")[0].strip()
                if name and name not in available:
                    line_no = code.count("\n", 0, match.start()) + 1
                    warnings.append(
                        f"{rel}:{line_no}: '{name}' not exported by "
                        f"{target.relative_to(ROOT)}"
                    )

        # 4. class fields without initializer (track brace depth to skip interfaces)
        in_interface = False
        in_class = False
        brace_depth = 0
        interface_depth = 0
        class_depth = 0
        for idx, line in enumerate(code_lines, start=1):
            if INTERFACE_OPEN_RE.match(line) and "{" in line:
                in_interface = True
                interface_depth = brace_depth
            elif CLASS_OPEN_RE.match(line) and "{" in line:
                in_class = True
                class_depth = brace_depth

            brace_depth += line.count("{") - line.count("}")

            if in_interface and brace_depth <= interface_depth:
                in_interface = False
            if in_class and brace_depth <= class_depth:
                in_class = False

            if not in_class:
                continue
            m = FIELD_NO_INIT_RE.match(line)
            if not m:
                continue
            name, ftype = m.group(1), m.group(2).strip()
            # `?` optional members are legal without initializer
            if name in {"return", "break", "continue", "case"} or ftype.endswith("?"):
                continue
            if line.strip().startswith("@"):
                continue
            # assigned in the constructor is also legal in ArkTS
            if re.search(rf"this\.{re.escape(name)}\s*=", code):
                continue
            warnings.append(f"{rel}:{idx}: class field '{name}' has no initializer")

    # 4b. ArkUI requires build() to have exactly ONE root component.
    #     A top-level `if` / `ForEach` in build() is the classic violation.
    BUILD_RE = re.compile(r"^\s*build\s*\(\s*\)\s*\{", re.MULTILINE)
    for path in files:
        rel = path.relative_to(ROOT)
        code = strip_comments(path.read_text(encoding="utf-8", errors="replace"))
        for m in BUILD_RE.finditer(code):
            tail = code[m.end():]
            first = tail.lstrip()
            token = re.match(r"[A-Za-z_$][\w$]*", first)
            if token is not None and token.group(0) in ("if", "ForEach", "LazyForEach", "else"):
                line_no = code.count("\n", 0, m.end()) + 1
                errors.append(
                    f"{rel}:{line_no}: build() starts with `{token.group(0)}`; "
                    f"ArkUI requires a single root component"
                )

    # 5. config sanity
    required = [
        "build-profile.json5",
        "oh-package.json5",
        "hvigorfile.ts",
        "hvigor/hvigor-config.json5",
        "AppScope/app.json5",
        "AppScope/resources/base/element/string.json",
        "entry/build-profile.json5",
        "entry/oh-package.json5",
        "entry/hvigorfile.ts",
        "entry/src/main/module.json5",
        "entry/src/main/resources/base/profile/main_pages.json",
        "entry/src/main/resources/base/element/color.json",
        "entry/src/main/resources/base/element/string.json",
    ]
    for cfg in required:
        if not (ROOT / cfg).exists():
            errors.append(f"missing required config: {cfg}")

    pages_file = ROOT / "entry/src/main/resources/base/profile/main_pages.json"
    if pages_file.exists():
        pages = json.loads(pages_file.read_text(encoding="utf-8"))
        for page in pages.get("src", []):
            if not (SRC / f"{page}.ets").exists():
                errors.append(f"main_pages.json references missing page: {page}")

    # referenced media resources must exist
    media_dir = ROOT / "entry/src/main/resources/base/media"
    have_media = {p.stem for p in media_dir.glob("*.svg")} | {p.stem for p in media_dir.glob("*.png")}
    media_refs: set[str] = set()
    for path in files:
        code = strip_comments(path.read_text(encoding="utf-8", errors="replace"))
        media_refs |= set(re.findall(r"\$r\('app\.media\.([\w.]+)'\)", code))
    for ref in sorted(media_refs - have_media):
        errors.append(f"missing media resource: app.media.{ref}")

    # resource references inside module.json5 / app.json5
    element_str = ROOT / "entry/src/main/resources/base/element/string.json"
    element_color = ROOT / "entry/src/main/resources/base/element/color.json"
    app_str = ROOT / "AppScope/resources/base/element/string.json"
    app_media = ROOT / "AppScope/resources/base/media"

    have_strings = {e["name"] for e in json.loads(element_str.read_text(encoding="utf-8"))["string"]}
    have_strings |= {e["name"] for e in json.loads(app_str.read_text(encoding="utf-8"))["string"]}
    have_colors = {e["name"] for e in json.loads(element_color.read_text(encoding="utf-8"))["color"]}
    have_profile = {p.stem for p in (ROOT / "entry/src/main/resources/base/profile").glob("*.json")}
    have_app_media = {p.stem for p in app_media.glob("*.png")}

    for cfg in ["entry/src/main/module.json5", "AppScope/app.json5"]:
        text = (ROOT / cfg).read_text(encoding="utf-8")
        for kind, pool in (
            ("string", have_strings),
            ("color", have_colors),
            ("media", have_media | have_app_media),
            ("profile", have_profile),
        ):
            # single capture group so findall yields plain strings
            for ref in re.findall(rf"\${kind}:([\w.]+)", text):
                if ref not in pool:
                    errors.append(f"{cfg}: $ref {kind}:{ref} does not exist")

    print(f"scanned {len(files)} .ets files")
    print(f"media resources referenced: {len(media_refs)} / available: {len(have_media)}\n")
    if errors:
        print(f"=== ERRORS ({len(errors)}) ===")
        for e in errors:
            print("  " + e)
    if warnings:
        print(f"\n=== WARNINGS ({len(warnings)}) ===")
        for w in warnings:
            print("  " + w)
    if not errors and not warnings:
        print("clean")

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
