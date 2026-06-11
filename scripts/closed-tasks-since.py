#!/usr/bin/env python3
"""List TODO.md tasks closed between a previous git ref and the working tree (#305).

Diffs the **Closed** table of `TODO.md` against its version at `--since <ref>` and
prints the newly-closed rows as a markdown bullet list — `- #ID title — resolution`
— for the GitHub Release notes (release.yml appends the output under a heading).
No new closed rows, no `--since`, or no prior `TODO.md` → prints nothing, so the
caller simply omits the section. Stdlib only (mirrors scripts/parity_check.py).
"""

import argparse
import re
import subprocess
import sys

# A Closed-table row: | NNN | theme | title | resolution |
# The header row ("| ID | Theme | …") and separator ("|---|…") don't match (\d{3}).
ROW = re.compile(r"^\|\s*(\d{3})\s*\|\s*[^|]*\|\s*(.+?)\s*\|\s*(.*?)\s*\|\s*$")


def closed_rows(text: str) -> dict[str, tuple[str, str]]:
    """Map id -> (title, resolution) for rows under the `## Closed` heading."""
    out: dict[str, tuple[str, str]] = {}
    in_closed = False
    for line in text.splitlines():
        if line.startswith("## Closed"):
            in_closed = True
            continue
        if in_closed and line.startswith("## "):
            break  # next top-level section ends the Closed table
        if not in_closed:
            continue
        m = ROW.match(line)
        if m:
            out[m.group(1)] = (m.group(2).strip(), m.group(3).strip())
    return out


def file_at_ref(ref: str, path: str) -> str:
    try:
        return subprocess.check_output(
            ["git", "show", f"{ref}:{path}"], text=True, stderr=subprocess.DEVNULL
        )
    except subprocess.CalledProcessError:
        return ""  # ref or file missing → treat as empty baseline


def main() -> None:
    ap = argparse.ArgumentParser(description="Newly-closed TODO.md tasks since a git ref (#305).")
    ap.add_argument("--since", default="", help="previous git ref/tag to diff against (empty → print nothing)")
    ap.add_argument("--todo", default="TODO.md", help="path to TODO.md (default: TODO.md)")
    args = ap.parse_args()

    if not args.since:
        return  # first release / no baseline → no section

    try:
        with open(args.todo, encoding="utf-8") as f:
            current = closed_rows(f.read())
    except FileNotFoundError:
        sys.exit(f"error: {args.todo} not found")

    previous = closed_rows(file_at_ref(args.since, args.todo))
    new_ids = sorted(set(current) - set(previous))
    for tid in new_ids:
        title, resolution = current[tid]
        line = f"- #{tid} {title}"
        if resolution and resolution != "—":
            line += f" — {resolution}"
        print(line)


if __name__ == "__main__":
    main()
