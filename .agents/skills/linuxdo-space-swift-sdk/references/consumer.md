# Consumer Guide

## Integrate

Current install model is SwiftPM source-package integration.

Import shape:

```swift
import LinuxDoSpace
```

## Full stream

```swift
let client = try Client(token: "lds_pat...")
for try await item in client.listen() {
    print(item.address)
}
await client.close()
```

## Mailbox binding

```swift
let box = try client.bind(prefix: "alice", suffix: .linuxdoSpace, allowOverlap: false)
for try await item in box.listen() {
    print(item.subject)
}
await box.close()
```

## Key semantics

- `Client.init(...)` starts the upstream bootstrap immediately.
- `route(_:)` is local matching only.
- Full-stream messages use a primary projection address.
- Mailbox messages use matched-recipient projection addresses.

