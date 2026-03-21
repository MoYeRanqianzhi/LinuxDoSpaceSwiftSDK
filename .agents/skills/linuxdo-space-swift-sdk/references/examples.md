# Task Templates

## Create one exact mailbox

```swift
let alice = try client.bind(prefix: "alice", suffix: .linuxdoSpace, allowOverlap: false)
```

## Create one catch-all

```swift
let catchAll = try client.bind(pattern: ".*", suffix: .linuxdoSpace, allowOverlap: true)
```

## Route one message locally

```swift
let targets = client.route(message)
```

