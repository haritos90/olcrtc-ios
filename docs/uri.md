# `olcrtc://` URI format

The connection-sharing URI produced by `OlcrtcURI.encode` and parsed by
`OlcrtcURI.parse`. It carries everything the client needs to start a tunnel,
so it must be treated as a secret (it contains the encryption key).

```
olcrtc://<carrier>?<transport>[<params>]@<roomID>#<key>[%<clientID>][$<mimo>]
```

## Components

| Part | Required | Meaning |
|---|---|---|
| `<carrier>` | yes | Conferencing platform used as the transport — e.g. `telemost`, `wbstream`, `jitsi`. |
| `<transport>` | yes | Channel type: `datachannel`, `vp8channel`, `seichannel`, or `videochannel`. |
| `[<params>]` | no | Inline tuning in `[k=v,k=v]` form, e.g. `[vp8-fps=15,vp8-batch=8]`. Overrides the app's global defaults for this connection only. |
| `<roomID>` | yes | Room identifier. For `jitsi` this may be a full room URL. |
| `<key>` | yes | 64-character hex encryption key (the shared secret). |
| `%<clientID>` | no | Legacy client identifier. Defaults to `default`; the server no longer filters on it, so new URIs omit it. |
| `$<mimo>` | no | Sub-config name. Server-side this is `sub_configname` / the `OLCRTC_CONFIG_NAME` env var (`scripts/srv.sh`). |

## Notes

- Delimiters are positional: `?` introduces the transport, `[...]` the inline
  params, `@` the room, `#` the key, `%` the optional client id, `$` the
  optional mimo/sub-config name.
- `<key>` and `socksPass` are never persisted to `UserDefaults` — they live in
  the Keychain (`ConnectionSecretStore`). The URI is the only place the key
  travels in plaintext, which is why sharing it grants full access.
- The parser tolerates a missing `%<clientID>` and `$<mimo>` (both optional).

See `App/Models/OlcrtcURI.swift` for the encoder/parser and round-trip tests in
`Tests/`.
