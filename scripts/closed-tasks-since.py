#!/usr/bin/env python3
"""List TODO.md tasks closed between a previous git ref and the working tree (#305).

Diffs the **Closed** table of `TODO.md` against its version at `--since <ref>` and
prints the newly-closed rows as a markdown bullet list — `- #ID release-note` —
for the GitHub Release notes (release.yml appends the output under a heading).
#315: the bullet text is the row's **Release note** column (the short,
user-facing "what's new" line filled in when the task is closed); rows without
one (legacy/`—`) fall back to the task title. The verbose **Resolution** column
is deliberately NOT emitted — it's TODO.md history, not release copy.
No new closed rows, no `--since`, or no prior `TODO.md` → prints nothing, so the
caller simply omits the section. Stdlib only (mirrors scripts/parity_check.py).
"""

import argparse
import re
import subprocess
import sys

# A Closed-table row: | NNN | theme | title | resolution | release-note | (#315).
# The header row ("| ID | Theme | …") and separator ("|---|…") don't match (\d+).
# #310: \d+ instead of \d{3} so IDs >= 1000 still match (header/separator/"—"
# placeholder rows still don't start with one-or-more digits, so they're excluded).
# #315: `[^|]` cell bodies (a markdown cell can't contain a raw `|` anyway) so
# the five cells can't glob into each other.
ROW5 = re.compile(r"^\|\s*(\d+)\s*\|\s*[^|]*\|\s*([^|]+?)\s*\|\s*([^|]*?)\s*\|\s*([^|]*?)\s*\|\s*$")
# #315 was: ROW (the only shape) — kept as the fallback for historic TODO.md
# revisions read via `--since`, which predate the Release-note column.
ROW4 = re.compile(r"^\|\s*(\d+)\s*\|\s*[^|]*\|\s*(.+?)\s*\|\s*(.*?)\s*\|\s*$")


def closed_rows(text: str) -> dict[str, tuple[str, str, str]]:
    """Map id -> (title, resolution, note) for rows under the `## Closed` heading."""
    out: dict[str, tuple[str, str, str]] = {}
    in_closed = False
    for line in text.splitlines():
        if line.startswith("## Closed"):
            in_closed = True
            continue
        if in_closed and line.startswith("## "):
            break  # next top-level section ends the Closed table
        if not in_closed:
            continue
        # #315: five-column shape first; fall back to the pre-#315 four-column
        # shape (historic revisions) with an empty note.
        if m := ROW5.match(line):
            out[m.group(1)] = (m.group(2).strip(), m.group(3).strip(), m.group(4).strip())
        elif m := ROW4.match(line):
            out[m.group(1)] = (m.group(2).strip(), m.group(3).strip(), "")
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
    # #310: numeric sort so "1000" sorts after "999" (string sort would put
    # "1000" before "100"/"999").
    new_ids = sorted(set(current) - set(previous), key=int)
    for tid in new_ids:
        title, resolution, note = current[tid]
        # #315 was: `- #ID title — resolution` — too verbose for release copy.
        # The Release note column is the curated line; title is the fallback.
        text = note if note and note != "—" else title
        print(f"- #{tid} {text}")


if __name__ == "__main__":
    main()
