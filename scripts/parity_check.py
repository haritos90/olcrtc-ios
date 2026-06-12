#!/usr/bin/env python3
"""
parity_check.py

Verifies that scripts/srv.sh (our patched copy) stays aligned with
olcrtc-upstream/script/srv.sh (upstream) — in BOTH directions (#325).

How it works
------------
scripts/srv.sh is a full copy of upstream with our modifications clearly
marked using two kinds of pair comments:

    # boc olcrtc-ios: <description of what we changed and why>
    <our replacement code — may differ from upstream>
    # eoc olcrtc-ios

    # boc olcrtc-ios-rejected: <why we deliberately do NOT take these lines>
    # <verbatim upstream line, commented out with "# ">
    # <verbatim upstream line, commented out with "# ">
    # eoc olcrtc-ios-rejected

A rejected block (#325) carries upstream lines we consciously decided not to
adopt — commented out so they never execute, verbatim so the checker can match
them against upstream. The reason lives on the `boc` line itself; every other
line inside the block MUST be `# ` + the exact upstream line (no free-form
comments inside — they would be read as payload).

Every line of ours is therefore one of: same-as-upstream (base), ours
(inside boc/eoc), or rejected (commented copy inside a rejected block).
Every executable upstream line is one of: adopted (in our base, or carried
verbatim inside a boc patch), rejected, or unaccounted.

Invariants checked
------------------
1. Every `# boc …` has a matching `# eoc …`; no nesting; rejected blocks
   contain only `# `-prefixed payload lines.
2. Every base line of ours must appear verbatim in upstream (upstream changed
   or dropped a line we rely on → fail).
3. Every rejected payload line must still exist in upstream (upstream dropped
   it → the rejection is stale and must be deleted → fail).
4. Every executable upstream line must be adopted or rejected — an
   unaccounted line (e.g. a new upstream env var or install step) fails the
   build: adopt it, or wrap it in a rejected block with a reason, AND file a
   TODO.md task for the triage decision.
5. Base lines should appear in upstream order — a reorder produces a warning
   (not a failure: duplicates like `echo ""` make strict ordering unprovable).

Blank lines and pure-comment lines are ignored on both sides — only
executable lines need an adopt/reject decision.

What we do NOT compare
----------------------
cnc.sh (client-side script): runs the olcrtc CLI binary on Linux/macOS.
On iOS the client is Mobile.xcframework (gomobile bindings), so there is
no 1-to-1 correspondence to compare.
"""

import os
import sys

SRCROOT  = os.environ.get(
    "SRCROOT",
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
OURS     = os.path.join(SRCROOT, "scripts", "srv.sh")
UPSTREAM = os.path.join(SRCROOT, "olcrtc-upstream", "script", "srv.sh")

BOC     = "# boc olcrtc-ios"
EOC     = "# eoc olcrtc-ios"
# #325: rejected-block markers. NB: they share the BOC/EOC prefix, so they
# must be tested BEFORE the plain markers everywhere below.
REJ_BOC = "# boc olcrtc-ios-rejected:"
REJ_EOC = "# eoc olcrtc-ios-rejected"


def read(path):
    try:
        with open(path) as f:
            return f.readlines()
    except FileNotFoundError:
        print(f"error: [parity] {path} not found — "
              f"run: git submodule update --init")
        sys.exit(1)


def split_sections(lines):
    """
    Walk our patched srv.sh once and return:
      - base:     [(line_no, text), ...] lines OUTSIDE any marker block
      - ours:     [(line_no, text), ...] replacement code inside boc/eoc blocks
      - rejected: [(line_no, text), ...] un-commented payload of rejected blocks
      - balance_errors: [(line_no, message), ...] structural problems

    Line numbers are 1-based to match what editors show.
    """
    base = []
    ours = []
    rejected = []
    balance_errors = []
    mode = None        # None | "ours" | "rejected"
    open_line = None   # line number of the currently open marker

    for n, raw in enumerate(lines, start=1):
        stripped = raw.rstrip()
        s = stripped.strip()

        # #325: rejected markers first — REJ_BOC starts with BOC.
        if s.startswith(REJ_BOC):
            if mode is not None:
                balance_errors.append(
                    (n, f"nested marker (previous block opened at line {open_line})"))
            if not s[len(REJ_BOC):].strip():
                balance_errors.append(
                    (n, "rejected block without a reason after the colon"))
            mode, open_line = "rejected", n
            continue
        if s.startswith(REJ_EOC):
            if mode != "rejected":
                balance_errors.append(
                    (n, f"'{REJ_EOC}' without a matching '{REJ_BOC}'"))
            mode, open_line = None, None
            continue
        if s.startswith(BOC):
            if mode is not None:
                balance_errors.append(
                    (n, f"nested marker (previous block opened at line {open_line})"))
            mode, open_line = "ours", n
            continue
        if s.startswith(EOC):
            if mode != "ours":
                balance_errors.append(
                    (n, f"'{EOC}' without a matching '{BOC}'"))
            mode, open_line = None, None
            continue

        if mode is None:
            base.append((n, stripped))
        elif mode == "rejected":
            # Payload must be `# ` + verbatim upstream line ("#" alone = blank).
            if s == "#" or not s:
                continue
            if not stripped.lstrip().startswith("# "):
                balance_errors.append(
                    (n, "rejected-block line must be '# ' + verbatim upstream line"))
                continue
            rejected.append((n, stripped.lstrip()[2:]))
        elif mode == "ours":
            # Our replacement code — exempt from the base check, but an
            # upstream line carried verbatim inside a boc patch still counts
            # as adopted for the upstream-side accounting below.
            ours.append((n, stripped))

    if mode is not None:
        balance_errors.append((open_line, "marker block never closed"))

    return base, ours, rejected, balance_errors


def executable(text):
    """Comparison scope: skip blanks and pure comments."""
    s = text.strip()
    return bool(s) and not s.startswith("#")


print("note: [parity] Checking scripts/srv.sh vs olcrtc-upstream/script/srv.sh ...")

ours_lines     = read(OURS)
upstream_lines = read(UPSTREAM)

base, ours_block, rejected, balance_errors = split_sections(ours_lines)

# Bail early on structural problems — classifying content is meaningless if
# we don't know which lines belong to which block.
if balance_errors:
    print(f"error: [parity] {len(balance_errors)} marker issue(s) in scripts/srv.sh:")
    for line_no, msg in balance_errors:
        print(f"  srv.sh:{line_no}: {msg}")
    sys.exit(1)

upstream_exec = [l.rstrip() for l in upstream_lines if executable(l.rstrip())]
upstream_set  = set(upstream_exec)
base_exec     = [(n, t) for n, t in base if executable(t)]
base_set      = {t for _, t in base_exec}
ours_set      = {t for _, t in ours_block if executable(t)}
rejected_set  = {t for _, t in rejected}

errors = []

# 2. Our base lines must exist verbatim in upstream (the pre-#325 check).
for line_no, text in base_exec:
    if text not in upstream_set:
        errors.append(("base", line_no, text))

# 3. #325: rejected payload must still exist in upstream — otherwise the
#    rejection is stale (upstream dropped the line) and should be deleted.
for line_no, text in rejected:
    if text not in upstream_set:
        errors.append(("stale-rejected", line_no, text))

# 4. #325: every executable upstream line must be adopted (in our base, or
#    carried verbatim inside a boc patch) or rejected.
unaccounted = [(i, t) for i, t in enumerate(upstream_exec, start=1)
               if t not in base_set and t not in ours_set and t not in rejected_set]

if errors:
    print(f"error: [parity] {len(errors)} line(s) in scripts/srv.sh failed the upstream match.")
    print("       base: upstream changed/dropped a line we rely on — re-sync it, or wrap it")
    print("             in a `# boc olcrtc-ios` block if it is a deliberate patch.")
    print("       stale-rejected: upstream no longer has the line — delete it from the")
    print("             rejected block.")
    print("       Next step:  diff -u olcrtc-upstream/script/srv.sh scripts/srv.sh | less")
    print()
    for kind, line_no, text in errors[:10]:
        print(f"  srv.sh:{line_no}: {kind}: {text!r}")
    if len(errors) > 10:
        print(f"  ... and {len(errors) - 10} more")
    sys.exit(1)

if unaccounted:
    print(f"error: [parity] {len(unaccounted)} upstream line(s) are neither adopted nor rejected.")
    print("       Upstream added or changed lines we have no decision for. For each one:")
    print("       ADOPT it (copy it into scripts/srv.sh at the matching spot), or REJECT it")
    print("       (add it, commented with '# ', to a `# boc olcrtc-ios-rejected: <reason>`")
    print("       block) — and file a TODO.md task recording the triage decision")
    print("       (what we take, what we skip, and why).")
    print()
    for idx, text in unaccounted[:10]:
        print(f"  upstream srv.sh (exec line {idx}): unaccounted: {text!r}")
    if len(unaccounted) > 10:
        print(f"  ... and {len(unaccounted) - 10} more")
    sys.exit(1)

# 5. #325: order check (warning only) — our base lines should follow upstream
#    order. Greedy walk: each base line consumes the next upstream occurrence;
#    a line only found *behind* the cursor was reordered (or duplicated).
cursor = 0
positions = {}
for i, t in enumerate(upstream_exec):
    positions.setdefault(t, []).append(i)
reordered = []
for line_no, text in base_exec:
    ahead = [i for i in positions[text] if i >= cursor]
    if ahead:
        cursor = ahead[0] + 1
    else:
        reordered.append((line_no, text))
for line_no, text in reordered[:5]:
    print(f"warning: [parity] srv.sh:{line_no}: out of upstream order: {text!r}")
if len(reordered) > 5:
    print(f"warning: [parity] ... and {len(reordered) - 5} more out-of-order lines")

print(f"note: [parity] All checks passed — "
      f"{len(base_exec)} adopted, {len(rejected)} rejected, "
      f"{len(upstream_exec)} upstream lines accounted for.")
