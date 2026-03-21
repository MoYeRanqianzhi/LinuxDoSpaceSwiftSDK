---
name: linuxdo-space-swift-sdk
description: Use when writing or fixing Swift code that consumes or maintains the LinuxDoSpace Swift SDK under sdk/swift. Use for SwiftPM integration, Client construction, AsyncThrowingStream full-stream usage, mailbox bindings, allowOverlap semantics, lifecycle/error handling, release guidance, and local validation.
---

# LinuxDoSpace Swift SDK

Read [references/consumer.md](references/consumer.md) first for normal SDK usage.
Read [references/api.md](references/api.md) for exact public Swift API names.
Read [references/examples.md](references/examples.md) for task-shaped snippets.
Read [references/development.md](references/development.md) only when editing `sdk/swift`.

## Workflow

1. Treat this package as a SwiftPM source package with the public module `LinuxDoSpace`.
2. The SDK root relative to this `SKILL.md` is `../../../`.
3. Preserve these invariants:
   - one `Client` owns one upstream HTTPS stream
   - `Client.init(...)` starts the upstream bootstrap
   - `client.listen()` is the full-stream `AsyncThrowingStream`
   - `try client.bind(...)` creates local mailbox bindings
   - `box.listen()` is the mailbox `AsyncThrowingStream`
   - mailbox queues activate only while mailbox listen is active
   - `Suffix.linuxdoSpace` is semantic and resolves after `ready.owner_username`
   - exact and regex bindings share one ordered chain per suffix
   - `allowOverlap=false` stops at first match; `true` continues
4. Keep README, Package.swift, source, and workflows aligned when behavior changes.
5. Validate with the commands in `references/development.md`.

## Do Not Regress

- Do not document CocoaPods/Carthage/XCFramework publication; current release output is source archives.
- Do not add hidden pre-listen mailbox buffering.
- Do not imply there is a separate `bindExact` / `bindPattern` API; Swift uses one unified `bind(...)`.
