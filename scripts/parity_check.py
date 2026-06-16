#!/usr/bin/env python3
"""
parity_check.py

Verifies that scripts/srv.sh (our patched copy) stays aligned with
olcrtc-upstream/script/srv.sh (upstream) — in BOTH directions (#325), and
LINE-BY-LINE IN ORDER for the lines we actually run, not by set membership
(a set lookup calls a moved / duplicated / out-of-context line "present" and
passes a drift it shouldn't).

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
line inside the block MUST be `# ` + the exact upstream line.

Every executable line of ours is one of: same-as-upstream (base), ours (our
replacement inside boc/eoc), or rejected (commented verbatim copy inside a
rejected block).

Two kinds of lines, two kinds of check
--------------------------------------
- BASE lines are the lines we actually RUN, and they sit in upstream's order
  (srv.sh is a copy; we don't reorder executable code). They are checked
  POSITIONALLY — line by line, in order, against upstream — so a base line is
  only accepted when it appears at the right place in the upstream sequence.
  This is the part the operator asked to harden: a forward two-pointer walk
  (with an inner forward scan per line — the "double loop"; the script is small
  so the O(n·m) cost is negligible) instead of `text in upstream_set`.
- REJECTED lines are commented-out and deliberately GROUPED by theme (#325
  consolidated all skipped upstream lines into a few rejected blocks), so their
  position in our file is NOT meaningful — they don't reconstruct upstream's
  order. The only thing that matters for a rejected line is whether the
  rejection is still valid, i.e. whether upstream STILL HAS that line. So
  rejected lines get an existence check (is this rejection stale?), not a
  positional one. (They are never executed, so position carries no risk.)

Algorithm
---------
Walk our srv.sh into an ordered stream: each base line is a "base" token; each
`# boc olcrtc-ios` patch start emits a "patch" marker; rejected lines are
collected aside (text set + line list). Then walk the base/patch stream against
the ordered upstream executable lines with one forward cursor `ui`:

  - base token → forward-scan upstream from `ui` for an exact match.
      * found at j → consume it (ui = j + 1). Upstream lines skipped to reach it
        (ui..j-1) form a GAP: each gap line must be accounted — licensed by an
        `# boc` patch seen since the last match (a region we replaced), present
        in the rejected set (a line we explicitly skipped), or a dropped
        duplicate of a base line we already run (#399 — e.g. upstream's second
        identical `echo ""` when our copy keeps only one; carries no new
        decision). Any other gap line is UNACCOUNTED (a new upstream line we
        never decided on → fail).
      * not found at/after `ui` → base-drift: upstream changed/dropped/moved a
        line we run → fail.
  - patch marker → set `patch_pending` (licenses the next gap as replaced).
  - After the walk, trailing upstream lines are accounted the same way (patch or
    rejected), else unaccounted.
  - Separately, every rejected line must still exist in upstream (else the
    rejection is stale and must be updated/deleted → fail).

Invariants checked
------------------
1. Every `# boc …` has a matching `# eoc …`; no nesting; rejected blocks
   contain only `# `-prefixed payload lines.
2. Every base line appears in upstream IN ORDER (positional) — else base-drift.
3. Every rejected line still exists in upstream (existence) — else stale.
4. Every executable upstream line is accounted: positionally matched by a base
   line, replaced by an `# boc` patch, or present in the rejected set. An
   unaccounted line (a new env var, install step, …) fails the build: adopt it,
   or reject-it-with-a-reason, AND file a TODO.md triage task.

Blank lines and pure-comment lines are ignored on both sides. (Edge case:
a genuinely-new upstream line that lands inside a gap we already patch is
absorbed by that patch rather than flagged — acceptable, the region is one we
have reviewed.)

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


def executable(text):
    """Comparison scope: skip blanks and pure comments."""
    s = text.strip()
    return bool(s) and not s.startswith("#")


def parse_ours(lines):
    """
    Walk our patched srv.sh once. Returns (stream, rejected, balance_errors):

      stream:   ordered list of base/patch tokens (in document order):
                  {"kind": "base",  "n": line_no, "text": <verbatim upstream line>}
                  {"kind": "patch", "n": line_no}   # one per `# boc olcrtc-ios` start
      rejected: list of (line_no, text) for rejected-block payload lines
      balance_errors: [(line_no, message), ...] structural problems
    Line numbers are 1-based.
    """
    stream = []
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
            # One patch marker per `# boc` block: it licenses the upstream lines
            # this block replaces (the next base match may skip them).
            stream.append({"kind": "patch", "n": n})
            continue
        if s.startswith(EOC):
            if mode != "ours":
                balance_errors.append(
                    (n, f"'{EOC}' without a matching '{BOC}'"))
            mode, open_line = None, None
            continue

        if mode is None:
            if executable(stripped):
                stream.append({"kind": "base", "n": n, "text": stripped})
        elif mode == "rejected":
            # Payload must be `# ` + verbatim upstream line ("#" alone = blank).
            if s == "#" or not s:
                continue
            if not stripped.lstrip().startswith("# "):
                balance_errors.append(
                    (n, "rejected-block line must be '# ' + verbatim upstream line"))
                continue
            payload = stripped.lstrip()[2:]
            if executable(payload):
                rejected.append((n, payload))
        elif mode == "ours":
            # Our replacement code — not a claim against upstream. The "patch"
            # marker emitted at the block start already licenses the gap.
            pass

    if mode is not None:
        balance_errors.append((open_line, "marker block never closed"))

    return stream, rejected, balance_errors


# #399: the positional walk, extracted into a pure function so it can be
# self-tested (run `python3 scripts/parity_check.py --selftest`). Returns
# (drift_errors, unaccounted, n_base); inputs are the parsed base/patch stream,
# the ordered upstream executable lines, and the rejected / base text sets.
def account(stream, upstream_exec, rejected_set, base_set):
    drift_errors = []   # (line_no, text) base-drift — base line not in upstream in order
    unaccounted  = []   # (upstream_exec_index, text) — upstream line in a non-patched gap

    def account_gap(lo, hi, patched):
        """Upstream lines [lo, hi) skipped between base matches: each must be
        licensed by a patch, be a line we explicitly rejected, or be a dropped
        duplicate of a base line we already run (#399) — else unaccounted."""
        if patched:
            return  # the whole gap is a region our `# boc` patch replaced
        for k in range(lo, hi):
            line = upstream_exec[k]
            # #399: `line in base_set` accounts a dropped duplicate of an
            # already-adopted line (the first copy matched positionally; this is
            # a later copy we don't keep) — no new decision, so not unaccounted.
            if line not in rejected_set and line not in base_set:
                unaccounted.append((k + 1, line))

    ui = 0
    patch_pending = False
    n_base = 0

    for tok in stream:
        if tok["kind"] == "patch":
            patch_pending = True
            continue

        n_base += 1
        text = tok["text"]
        j = None
        for k in range(ui, len(upstream_exec)):
            if upstream_exec[k] == text:
                j = k
                break

        if j is None:
            drift_errors.append((tok["n"], text))
            patch_pending = False   # alignment broke here; don't mass-flag the rest
            continue

        account_gap(ui, j, patch_pending)
        ui = j + 1
        patch_pending = False

    # Trailing upstream lines after the last base match.
    account_gap(ui, len(upstream_exec), patch_pending)
    return drift_errors, unaccounted, n_base


def _selftest():
    """#399: exercise account() in isolation — focus on the dropped-duplicate
    accounting. Exits 0 on pass, 1 on failure; never touches the real files."""
    def base(text):  return {"kind": "base", "n": 0, "text": text}
    patch = {"kind": "patch", "n": 0}
    failures = []

    def check(name, cond):
        if not cond:
            failures.append(name)

    # 1. Dropped duplicate of an already-run line: upstream has `echo ""` twice
    #    in a row, our copy keeps only one. The 2nd copy lands in a gap and must
    #    be accounted (the #399 fix), not flagged unaccounted.
    up    = ["A", 'echo ""', 'echo ""', "B"]
    strm  = [base("A"), base('echo ""'), base("B")]
    bset  = {"A", 'echo ""', "B"}
    drift, unacc, _ = account(strm, up, set(), bset)
    check("dropped-dup: no drift",        drift == [])
    check("dropped-dup: nothing unacc",   unacc == [])

    # 2. Non-adjacent dropped duplicate (the line recurs much later upstream).
    up2   = ["A", 'echo ""', "B", "C", 'echo ""', "D"]
    strm2 = [base("A"), base('echo ""'), base("B"), base("C"), base("D")]
    bset2 = {"A", 'echo ""', "B", "C", "D"}
    drift2, unacc2, _ = account(strm2, up2, set(), bset2)
    check("nonadjacent-dup: no drift",      drift2 == [])
    check("nonadjacent-dup: nothing unacc", unacc2 == [])

    # 3. A genuinely NEW upstream line (not a duplicate of anything we run) must
    #    STILL be flagged unaccounted — the fix must not mask real new lines.
    up3   = ["A", "OLCRTC_NEW=1", "B"]
    strm3 = [base("A"), base("B")]
    bset3 = {"A", "B"}
    drift3, unacc3, _ = account(strm3, up3, set(), bset3)
    check("new-line: still unaccounted", [t for _, t in unacc3] == ["OLCRTC_NEW=1"])

    # 4. A new line in a gap our `# boc` patch covers is absorbed (patched).
    up4   = ["A", "OLCRTC_NEW=1", "B"]
    strm4 = [base("A"), patch, base("B")]
    bset4 = {"A", "B"}
    drift4, unacc4, _ = account(strm4, up4, set(), bset4)
    check("patched-gap: nothing unacc", unacc4 == [])

    # 5. A gap line we explicitly rejected is accounted via the rejected set.
    up5   = ["A", "OLCRTC_OLD=1", "B"]
    strm5 = [base("A"), base("B")]
    bset5 = {"A", "B"}
    drift5, unacc5, _ = account(strm5, up5, {"OLCRTC_OLD=1"}, bset5)
    check("rejected-gap: nothing unacc", unacc5 == [])

    # 6. A base line missing from upstream is base-drift.
    up6   = ["A", "B"]
    strm6 = [base("A"), base("GONE"), base("B")]
    bset6 = {"A", "GONE", "B"}
    drift6, _, _ = account(strm6, up6, set(), bset6)
    check("base-drift: flagged", [t for _, t in drift6] == ["GONE"])

    if failures:
        print("error: [parity] self-test FAILED:")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    print("note: [parity] self-test passed (6 cases).")
    sys.exit(0)


if "--selftest" in sys.argv[1:]:
    _selftest()


print("note: [parity] Checking scripts/srv.sh vs olcrtc-upstream/script/srv.sh ...")

ours_lines     = read(OURS)
upstream_lines = read(UPSTREAM)

stream, rejected, balance_errors = parse_ours(ours_lines)

# Bail early on structural problems — classifying content is meaningless if
# we don't know which lines belong to which block.
if balance_errors:
    print(f"error: [parity] {len(balance_errors)} marker issue(s) in scripts/srv.sh:")
    for line_no, msg in balance_errors:
        print(f"  srv.sh:{line_no}: {msg}")
    sys.exit(1)

upstream_exec = [l.rstrip() for l in upstream_lines if executable(l.rstrip())]
upstream_set  = set(upstream_exec)
rejected_set  = {t for _, t in rejected}
# #399: the texts of every base line we actually run. A gap line equal to one
# of these is a DROPPED DUPLICATE of a line we already adopted (e.g. upstream
# has two identical `echo ""` and our copy keeps only one) — the forward-walk
# matches the first occurrence, leaving the second in a gap. It carries no new
# decision (invariant 4 catches *new* env vars / install steps, not a repeat of
# a line we already run), so it must be accounted, not flagged UNACCOUNTED.
base_set      = {tok["text"] for tok in stream if tok["kind"] == "base"}

# --- 2 & 4: positional walk of base lines against upstream ------------------
drift_errors, unaccounted, n_base = account(
    stream, upstream_exec, rejected_set, base_set)

# --- 3: rejected lines must still exist in upstream (existence) -------------
stale_rejected = [(n, t) for n, t in rejected if t not in upstream_set]

if drift_errors:
    print(f"error: [parity] {len(drift_errors)} base line(s) in scripts/srv.sh did not "
          f"match upstream in order.")
    print("       base-drift: a line we run is gone from upstream, changed, or out of")
    print("             order at this position — re-sync it, or wrap it in a")
    print("             `# boc olcrtc-ios` block if it is a deliberate patch.")
    print("       Next step:  diff -u olcrtc-upstream/script/srv.sh scripts/srv.sh | less")
    print()
    for line_no, text in drift_errors[:10]:
        print(f"  srv.sh:{line_no}: base-drift: {text!r}")
    if len(drift_errors) > 10:
        print(f"  ... and {len(drift_errors) - 10} more")
    sys.exit(1)

if stale_rejected:
    print(f"error: [parity] {len(stale_rejected)} rejected line(s) no longer exist upstream.")
    print("       stale-rejected: upstream dropped the line, so the rejection is stale —")
    print("             delete it from its `# boc olcrtc-ios-rejected:` block.")
    print()
    for line_no, text in stale_rejected[:10]:
        print(f"  srv.sh:{line_no}: stale-rejected: {text!r}")
    if len(stale_rejected) > 10:
        print(f"  ... and {len(stale_rejected) - 10} more")
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

print(f"note: [parity] All checks passed — "
      f"{n_base} adopted (positional, in order), {len(rejected)} rejected, "
      f"{len(upstream_exec)} upstream lines accounted for.")
