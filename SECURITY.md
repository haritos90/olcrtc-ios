# Security Policy

`olcrtc-ios` is a proxy client; security reports are taken seriously. Please
report privately so users aren't exposed before a fix.

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Use GitHub's **"Report a vulnerability"** button (Security tab → Report a
vulnerability) to open a private advisory. Include:

- what the issue is and its impact (e.g. key/credential leak, MITM, traffic
  deanonymisation),
- steps or a proof of concept,
- affected build number (Settings → Info, e.g. `1.2.208`) and iOS version.

We'll acknowledge the report and keep you updated on the fix and disclosure
timeline.

## Scope

This repository is the **iOS app**: the SwiftUI client, the local SOCKS5
routing, secret storage, the VPS install flow, and the bundled
`Mobile.xcframework`.

Vulnerabilities in the **olcrtc core / protocol / server** belong upstream —
report them at <https://github.com/openlibrecommunity/olcrtc>.

## What's in scope here

- Leakage of the encryption key, SSH credentials, or the SOCKS5 password
  (Keychain handling, logs, the `olcrtc://` URI, backups).
- Local proxy / ATS / TLS-validation weaknesses (e.g. the DoH host-override
  path in `SubscriptionFetcher`).
- Anything that could deanonymise a user or expose that they run the app.

## Out of scope

- Social-engineering, physical access, or a jailbroken/compromised device.
- The conferencing platforms the tunnel rides on (Jitsi, Telemost, WBStream).
