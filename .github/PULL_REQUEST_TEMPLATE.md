<!-- Thanks for contributing! Keep everything in English (see CONTRIBUTING.md). -->

## What & why

<!-- What does this change and why. Link the TODO.md task id if there is one (e.g. "#231"). -->

## Type

<!-- Conventional Commits type — feat / fix / docs / refactor / test / build / chore -->

## Checklist

- [ ] Title follows [Conventional Commits](https://www.conventionalcommits.org/) (`type(scope): summary`)
- [ ] Builds and `xcodebuild test` passes (`166/166` or more)
- [ ] User-facing strings go through `L10n` (EN + RU), not hardcoded
- [ ] Bumped `CFBundleVersion` in `project.yml` for code changes (not for docs-only)
- [ ] Task-driven changes are marked (`// #NNN:` / `# boc olcrtc-ios`) per CONTRIBUTING.md
- [ ] `scripts/srv.sh` still passes `parity_check.py` (if touched)

## Notes for reviewers

<!-- Anything that needs attention: trade-offs, follow-ups, screenshots for UI changes. -->
