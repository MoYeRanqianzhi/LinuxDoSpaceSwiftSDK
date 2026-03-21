# API Reference

## Paths

- SDK root: `../../../`
- Package metadata: `../../../Package.swift`
- Core implementation: `../../../Sources/LinuxDoSpace/LinuxDoSpace.swift`
- Consumer README: `../../../README.md`

## Public surface

- Types: `Suffix`, `LinuxDoSpaceError`, `MailMessage`, `MailBox`, `Client`
- Client:
  - `init(...)`
  - `listen()`
  - `bind(prefix:pattern:suffix:allowOverlap:)`
  - `route(_:)`
  - `close()`
- MailBox:
  - `listen()`
  - `close()`
  - metadata properties `mode`, `suffix`, `allowOverlap`, `prefix`, `pattern`, `address`

## Semantics

- `Suffix.linuxdoSpace` is semantic, not literal.
- Exact and regex bindings share one ordered chain per suffix.
- `bind(...)` requires exactly one of `prefix` or `pattern`.
- Regex bindings are full-match local-part regexes.
