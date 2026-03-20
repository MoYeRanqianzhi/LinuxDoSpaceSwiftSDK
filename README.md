# LinuxDoSpace Swift SDK

This directory contains a Swift SDK implementation for LinuxDoSpace mail stream protocol.

## Scope

- `Client`, `Suffix`, `MailMessage`
- Errors: `LinuxDoSpaceError.authenticationFailed` and stream errors
- Full token listener stream (broadcast semantics for concurrent listeners)
- Local bind (exact/regex), ordered matching chain, overlap control
- `route`, `close`
- Multi-recipient dispatch keeps mailbox `message.address` as current recipient
- MIME header/body parsing fills common fields (`subject`, address headers, text/html)

Important:

- `Suffix.linuxdoSpace` is semantic, not literal
- the SDK resolves it to `<owner_username>.linuxdo.space` after `ready.owner_username`

## Local Verification Status

Current environment does not have Swift toolchain installed, so this SDK was not compiled locally in this session.

## Build (when Swift is available)

```bash
swift build
```
