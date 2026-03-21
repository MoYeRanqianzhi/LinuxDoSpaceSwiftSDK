# Development Guide

## Workdir

```bash
cd sdk/swift
```

## Validate

```bash
swift build
swift build -c release
```

## Release model

- Workflow file: `../../../.github/workflows/release.yml`
- Trigger: push tag `v*`
- Current release output is a source archive uploaded to GitHub Release

## Keep aligned

- `../../../Package.swift`
- `../../../Sources/LinuxDoSpace/LinuxDoSpace.swift`
- `../../../README.md`
- `../../../.github/workflows/ci.yml`
- `../../../.github/workflows/release.yml`
