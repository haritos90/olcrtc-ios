#!/usr/bin/env python3
"""
parity_check.py

Verifies that scripts/srv.sh (our patched copy) stays aligned with
olcrtc-upstream/script/srv.sh (upstream).

How it works
------------
scripts/srv.sh is a full copy of upstream with our modifications clearly
marked using pair comments:

    # boc olcrtc-ios: <description of what we changed and why>
    <our replacement code — may differ from upstream>
    # eoc olcrtc-ios

Invariants checked
------------------
1. Every # boc has a matching # eoc (no unmatched / nested markers).
2. Every line in scripts/srv.sh that is OUTSIDE a boc/eoc block
   must appear verbatim somewhere in upstream olcrtc-upstream/script/srv.sh.

If upstream changes a line we rely on (outside our patches), the build
fails — prompting a deliberate review and re-sync.

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

BOC = "# boc olcrtc-ios"
EOC = "# eoc olcrtc-ios"


def read(path):
    try:
        with open(path) as f:
            return f.readlines()
    except FileNotFoundError:
        print(f"error: [parity] {path} not found — "
              f"run: git submodule update --init")
        sys.exit(1)


def split_boc_eoc(lines):
    """
    Walk our patched srv.sh once and return:
      - base_lines:  [(line_no, text), ...] for lines OUTSIDE boc/eoc blocks
      - balance_errors: [(line_no, message), ...] for unmatched/nested markers

    Line numbers are 1-based to match what editors show.
    """
    base = []
    balance_errors = []
    inside = False
    boc_start = None   # line number of the unclosed # boc, when inside

    for n, raw in enumerate(lines, start=1):
        stripped = raw.rstrip()
        s = stripped.strip()

        if s.startswith(BOC):
            if inside:
                balance_errors.append(
                    (n, f"nested '# boc olcrtc-ios' (previous opened at line {boc_start})"))
            inside    = True
            boc_start = n
            continue

        if s.startswith(EOC):
            if not inside:
                balance_errors.append(
                    (n, "'# eoc olcrtc-ios' without a matching '# boc olcrtc-ios'"))
            inside    = False
            boc_start = None
            continue

        if not inside:
            base.append((n, stripped))

    if inside:
        balance_errors.append(
            (boc_start, "'# boc olcrtc-ios' never closed by '# eoc olcrtc-ios'"))

    return base, balance_errors


print("note: [parity] Checking scripts/srv.sh vs olcrtc-upstream/script/srv.sh ...")

ours_lines     = read(OURS)
upstream_lines = read(UPSTREAM)

base, balance_errors = split_boc_eoc(ours_lines)

# Bail early on structural problems — checking content is meaningless if
# we don't know which lines are inside our patches.
if balance_errors:
    print(f"error: [parity] {len(balance_errors)} boc/eoc balance issue(s) in scripts/srv.sh:")
    for line_no, msg in balance_errors:
        print(f"  srv.sh:{line_no}: {msg}")
    sys.exit(1)

upstream_set = {line.rstrip() for line in upstream_lines}

errors = []
for line_no, text in base:
    # Skip blank lines and pure-comment lines — those can differ without concern.
    stripped = text.strip()
    if not stripped or stripped.startswith("#"):
        continue
    if text not in upstream_set:
        errors.append((line_no, text))

if errors:
    print(f"error: [parity] {len(errors)} line(s) in scripts/srv.sh (outside boc/eoc) "
          f"not found in upstream olcrtc-upstream/script/srv.sh.")
    print("       Upstream may have changed lines we depend on. Review and update scripts/srv.sh.")
    print("       Next step:  diff -u olcrtc-upstream/script/srv.sh scripts/srv.sh | less")
    print("       Then either re-sync the drifted lines OR wrap them in a `# boc olcrtc-ios` / `# eoc olcrtc-ios` block if they are deliberate patches.")
    print()
    for line_no, text in errors[:10]:
        print(f"  srv.sh:{line_no}: not in upstream: {text!r}")
    if len(errors) > 10:
        print(f"  ... and {len(errors) - 10} more")
    sys.exit(1)

print("note: [parity] All checks passed.")
