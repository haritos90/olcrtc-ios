#!/usr/bin/env python3
"""Cut a release locally from the Backlog.md ledger.

Replaces the CI-side scripts/closed-tasks-since.py, which read the (now removed)
committed TODO.md. Because the task ledger is now local (backlog/ is gitignored),
CI can no longer compute the "tasks closed since the last release" section — so
it is produced here, on the maintainer's machine, and written into the annotated
tag's message. release.yml then builds + attaches the unsigned .ipa and
Mobile.xcframework and uses the tag message as the GitHub Release body.

What it does:
  1. reads MARKETING_VERSION + CFBundleVersion from project.yml -> tag v<mkt>.<build>
  2. scans the local backlog for Done tasks and their `**Release note:**` lines
  3. announces every Done task with a release note NOT already shipped (tracked in
     local/released-task-ids.txt) as `- #<ID> <note>`, ascending id
  4. creates the annotated tag with those notes as its message and pushes it
  5. records the announced ids so the next release only shows what's new

Usage:
  python3 scripts/cut-release.py --dry-run   # print the tag + notes, change nothing
  python3 scripts/cut-release.py --no-push    # create the tag locally, don't push
  python3 scripts/cut-release.py              # create + push the tag (triggers CI)

Stdlib only (mirrors scripts/parity_check.py).
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PROJECT = REPO / "project.yml"
BACKLOG = REPO / "backlog"
LEDGER = REPO / "local" / "released-task-ids.txt"


def project_version() -> tuple[str, str]:
    txt = PROJECT.read_text(encoding="utf-8")
    mkt = re.search(r"MARKETING_VERSION:\s*[\"']?([\w.]+)", txt)
    bld = re.search(r"CFBundleVersion:\s*[\"']?(\d+)", txt)
    if not mkt or not bld:
        sys.exit("error: MARKETING_VERSION / CFBundleVersion not found in project.yml")
    return mkt.group(1), bld.group(1)


def done_tasks() -> list[tuple[int, str]]:
    """(id, release-note) for every Done task that carries a Release note line."""
    if not BACKLOG.is_dir():
        sys.exit("error: backlog/ not found — is the ledger present on this machine?")
    out: list[tuple[int, str]] = []
    for sub in ("completed", "tasks"):
        for f in sorted((BACKLOG / sub).glob("task-*.md")):
            t = f.read_text(encoding="utf-8")
            if not re.search(r"^status:\s*Done\s*$", t, re.M):
                continue
            mid = re.search(r"^id:\s*TASK-(\d+)", t, re.M)
            note = re.search(r"^\*\*Release note:\*\*\s*(.+)$", t, re.M)
            if mid and note:
                out.append((int(mid.group(1)), note.group(1).strip()))
    return sorted(out)


def load_ledger() -> set[int]:
    if not LEDGER.exists():
        return set()
    return {int(x) for x in LEDGER.read_text().split() if x.strip().isdigit()}


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(REPO), *args], text=True,
                          capture_output=True, check=check)


def main() -> None:
    ap = argparse.ArgumentParser(description="Cut a release from the local Backlog.md ledger.")
    ap.add_argument("-m", "--message", default="",
                    help="custom headline for the tag message, like the old `git tag -a -m` "
                         "(replaces the default 'Release <tag>.' line; the What's-new task list follows it)")
    ap.add_argument("--dry-run", action="store_true", help="print the tag + notes, change nothing")
    ap.add_argument("--no-push", action="store_true", help="create the tag locally but do not push")
    args = ap.parse_args()

    mkt, build = project_version()
    tag = f"v{mkt}.{build}"

    released = load_ledger()
    new = [(i, n) for i, n in done_tasks() if i not in released]

    lines = [args.message.strip() if args.message else f"Release {tag}.", ""]
    if new:
        lines += ["**What's new**", ""]
        lines += [f"- #{i} {n}" for i, n in new]
    else:
        lines.append("Maintenance release — no newly-completed tasks to announce.")
    notes = "\n".join(lines).rstrip() + "\n"

    print(f"tag:                 {tag}")
    print(f"new tasks announced: {len(new)}")
    print("---- tag message / release notes ----")
    print(notes, end="")
    print("-------------------------------------")

    if args.dry_run:
        print("(dry run — nothing created or pushed)")
        return

    if git("rev-parse", "-q", "--verify", f"refs/tags/{tag}", check=False).returncode == 0:
        sys.exit(f"error: tag {tag} already exists — bump CFBundleVersion in project.yml first.")

    git("tag", "-a", tag, "-m", notes)
    print(f"created annotated tag {tag}")

    if args.no_push:
        print("--no-push: tag is local only; release + ledger update happen when you push it.")
        return

    git("push", "origin", tag)
    print(f"pushed {tag} — CI (release.yml) will build the .ipa + Mobile.xcframework and publish the Release.")

    if new:
        with LEDGER.open("a", encoding="utf-8") as fh:
            for i, _ in new:
                fh.write(f"{i}\n")
        print(f"recorded {len(new)} announced id(s) in {LEDGER.relative_to(REPO)}")


if __name__ == "__main__":
    main()
