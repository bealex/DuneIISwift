#!/usr/bin/env python3
"""Unwrap paragraph-internal line breaks in Markdown files.

Preserves:
- Blank lines (paragraph separators)
- Code fences (``` ... ```)
- Headings (# ...)
- List items (-, *, +, N.) — continuation lines are folded into their bullet
- Table rows (any line containing |)
- Horizontal rules (---, ***, ___)
- Reference-style link definitions ([label]: url)
- Blockquotes (> ...) — each block folded into one line
"""
import re
import sys
from pathlib import Path

RE_FENCE = re.compile(r"^\s*```")
RE_HEADING = re.compile(r"^\s*#")
RE_LIST = re.compile(r"^(\s*)([-*+]|\d+\.)\s+(.*)$")
RE_HR = re.compile(r"^\s*([-_*])\1{2,}\s*$")
RE_REFLINK = re.compile(r"^\s*\[[^\]]+\]:\s+")
RE_BLOCKQUOTE = re.compile(r"^\s*>\s?")


def is_special_line(line: str) -> bool:
    if not line.strip():
        return True
    if RE_HEADING.match(line):
        return True
    if RE_LIST.match(line):
        return True
    if "|" in line:
        return True
    if RE_HR.match(line):
        return True
    if RE_REFLINK.match(line):
        return True
    if RE_BLOCKQUOTE.match(line):
        return True
    if RE_FENCE.match(line):
        return True
    return False


def reflow(text: str) -> str:
    lines = text.split("\n")
    out: list[str] = []
    i = 0
    in_code = False

    while i < len(lines):
        line = lines[i]

        if RE_FENCE.match(line):
            in_code = not in_code
            out.append(line)
            i += 1
            continue

        if in_code:
            out.append(line)
            i += 1
            continue

        if not line.strip():
            out.append("")
            i += 1
            continue

        if RE_HEADING.match(line) or RE_HR.match(line) or RE_REFLINK.match(line) or "|" in line:
            out.append(line)
            i += 1
            continue

        list_match = RE_LIST.match(line)
        if list_match:
            indent, bullet, content = list_match.groups()
            parts = [content.rstrip()]
            base_indent = len(indent)
            i += 1
            while i < len(lines):
                nxt = lines[i]
                if not nxt.strip():
                    break
                nxt_list = RE_LIST.match(nxt)
                if nxt_list:
                    nxt_indent = len(nxt_list.group(1))
                    if nxt_indent <= base_indent:
                        break
                if RE_HEADING.match(nxt) or RE_HR.match(nxt) or RE_FENCE.match(nxt):
                    break
                if "|" in nxt or RE_REFLINK.match(nxt):
                    break
                parts.append(nxt.strip())
                i += 1
            out.append(f"{indent}{bullet} {' '.join(parts)}")
            continue

        if RE_BLOCKQUOTE.match(line):
            parts = [RE_BLOCKQUOTE.sub("", line).strip()]
            i += 1
            while i < len(lines) and RE_BLOCKQUOTE.match(lines[i]):
                parts.append(RE_BLOCKQUOTE.sub("", lines[i]).strip())
                i += 1
            out.append("> " + " ".join(parts))
            continue

        parts = [line.strip()]
        i += 1
        while i < len(lines) and not is_special_line(lines[i]):
            parts.append(lines[i].strip())
            i += 1
        out.append(" ".join(parts))

    collapsed: list[str] = []
    prev_blank = False
    for line in out:
        blank = not line.strip()
        if blank and prev_blank:
            continue
        collapsed.append(line)
        prev_blank = blank

    result = "\n".join(collapsed)
    if not result.endswith("\n"):
        result += "\n"
    return result


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: reflow_md.py FILE [FILE ...]", file=sys.stderr)
        return 2
    changed = 0
    for path_str in argv[1:]:
        path = Path(path_str)
        original = path.read_text(encoding="utf-8")
        reflowed = reflow(original)
        if reflowed != original:
            path.write_text(reflowed, encoding="utf-8")
            changed += 1
            print(f"reflowed: {path}")
    print(f"{changed} file(s) changed of {len(argv) - 1}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
