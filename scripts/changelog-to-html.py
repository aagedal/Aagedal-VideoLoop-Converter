#!/usr/bin/env python3
# Aagedal Media Converter
# Copyright © 2026 Truls Aagedal
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Extract the section for a given version from CHANGELOG.md and emit it as the
# HTML fragment Sparkle expects inside the appcast `<description>` CDATA.
#
# Usage:
#   ./scripts/changelog-to-html.py CHANGELOG.md 4.1.2
#
# Handles only the subset of Markdown the CHANGELOG actually uses:
#   - `##`/`###` headers (the leading `# v.X.Y.Z` line for the version is
#     dropped because Sparkle already shows the version in its dialog header)
#   - `-` / `*` bullet lists
#   - `**bold**`, `*italic*`, backtick code, `[text](url)` inline
#   - `> blockquote` (single-line)
#   - paragraphs separated by blank lines
#
# Anything more exotic should be flagged manually rather than silently mangled.
import html
import re
import sys
from pathlib import Path


def extract_section(text: str, version: str) -> str:
    """Return the markdown for `version` from CHANGELOG.md, without the
    `# v.X.Y.Z` header line itself."""
    # Match `# v.4.1.2` at the start of a line, capture everything up to the
    # next `# v.` (or end of file).
    pattern = re.compile(
        rf"^#\s*v\.?{re.escape(version)}\s*$\n(.*?)(?=^#\s*v\.|\Z)",
        re.MULTILINE | re.DOTALL,
    )
    m = pattern.search(text)
    if not m:
        raise SystemExit(f"Version {version} not found in CHANGELOG")
    return m.group(1).strip()


def render_inline(text: str) -> str:
    """Apply inline transformations: code, links, bold, italic. Order matters
    so e.g. URLs inside parentheses aren't mangled by the italic pass."""
    # 1. Inline code first — its contents must not be touched by other passes.
    placeholders: list[str] = []

    def stash_code(match: re.Match) -> str:
        placeholders.append(f"<code>{html.escape(match.group(1))}</code>")
        return f"\0CODE{len(placeholders) - 1}\0"

    text = re.sub(r"`([^`]+)`", stash_code, text)

    # 2. HTML-escape the remaining text so user content can't inject markup.
    text = html.escape(text, quote=False)

    # 3. Links: [label](url).
    def link(match: re.Match) -> str:
        label, url = match.group(1), match.group(2)
        return f'<a href="{html.escape(url, quote=True)}">{label}</a>'

    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", link, text)

    # 4. Bold then italic. `**x**` before `*x*` because `**` is two `*`.
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<em>\1</em>", text)

    # 5. Restore code placeholders.
    for i, value in enumerate(placeholders):
        text = text.replace(f"\0CODE{i}\0", value)

    return text


def render_block(md: str) -> str:
    """Convert a markdown CHANGELOG section to a HTML fragment."""
    out: list[str] = []
    lines = md.splitlines()
    i = 0

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        # Skip blank lines (paragraph separators handled implicitly).
        if not stripped:
            i += 1
            continue

        # Headers — `## Foo` → <h2>Foo</h2>.
        header = re.match(r"^(#{2,6})\s+(.*)", stripped)
        if header:
            level = len(header.group(1))
            out.append(f"<h{level}>{render_inline(header.group(2))}</h{level}>")
            i += 1
            continue

        # Blockquote — single line for now (no nested rendering).
        if stripped.startswith("> "):
            out.append(f"<blockquote>{render_inline(stripped[2:])}</blockquote>")
            i += 1
            continue

        # Bullet list — consume consecutive `-` / `*` items.
        if re.match(r"^[-*]\s+", stripped):
            out.append("<ul>")
            while i < len(lines):
                item = lines[i].strip()
                if not item:
                    i += 1
                    if i < len(lines) and re.match(r"^[-*]\s+", lines[i].strip()):
                        continue
                    break
                item_match = re.match(r"^[-*]\s+(.*)", item)
                if not item_match:
                    break
                out.append(f"<li>{render_inline(item_match.group(1))}</li>")
                i += 1
            out.append("</ul>")
            continue

        # Paragraph — collect contiguous non-blank lines.
        paragraph: list[str] = []
        while i < len(lines) and lines[i].strip() and not (
            re.match(r"^#{2,6}\s+", lines[i].strip())
            or re.match(r"^[-*]\s+", lines[i].strip())
            or lines[i].strip().startswith("> ")
        ):
            paragraph.append(lines[i].strip())
            i += 1
        if paragraph:
            out.append(f"<p>{render_inline(' '.join(paragraph))}</p>")

    return "\n".join(out)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: changelog-to-html.py <CHANGELOG.md> <version>", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    version = sys.argv[2]
    text = path.read_text(encoding="utf-8")
    section = extract_section(text, version)
    print(render_block(section))
    return 0


if __name__ == "__main__":
    sys.exit(main())
