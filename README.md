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
- `Suffix.linuxdoSpace` now resolves to the current token owner's canonical
  mail namespace: `<owner_username>-mail.linuxdo.space`
- `try Suffix.linuxdoSpace.withSuffix("foo")` resolves to
  `<owner_username>-mailfoo.linuxdo.space`
- active semantic `-mail<suffix>` registrations are synchronized to
  `PUT /v1/token/email/filters`
- the legacy default alias `<owner_username>.linuxdo.space` still matches the
  default semantic binding automatically

## Local Verification Status

Current environment does not have Swift toolchain installed, so this SDK was not compiled locally in this session.

## Build (when Swift is available)

```bash
swift build
```
