# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases take their notes from this file, so the section for a version has to exist before that
version can be tagged. See [Releasing](CONTRIBUTING.md#releasing).

## [Unreleased]

### Added

- `ConfigDirectorClient`, evaluating configs against a `ConfigDirectorContext` of `id`, `name`,
  `traits` and `isAnonymous`. `updateContext(_:)` re-evaluates every config against a new identity,
  keeping the previous one in effect until the reconnection succeeds or times out.
- Synchronous `value(for:default:)`, safe to call from a SwiftUI `body`. `Bool`, `String`, `Int` and
  `Double` are supported, and any type can be read from a config by conforming to `ConfigValue`.
- `value(for:as:default:)`, decoding a JSON config into any `Decodable` type.
- `values(for:default:)`, an `AsyncStream` that yields the current value on subscription and then
  each change, without re-emitting a value that did not change.
- Three connection modes: `.streaming` over server-sent events, `.polling` on an interval, and
  `.oneTime`. Streaming reconnects on its own with a backoff, and stops on an unrecoverable status.
- Telemetry that aggregates config evaluations and reports them off the caller's thread, so
  evaluating a config never waits on the network.
- `pausesWhileBackgrounded`, dropping the connection while the app is backgrounded and restoring it
  on return, plus `pauseNetwork()` and `resumeNetwork()` to drive that manually.
- `events` and `evaluations` streams, publishing client lifecycle changes and every individual
  config evaluation.
- `ConfigDirectorLogger`, with a `ConsoleLogger` writing to the unified logging system under the
  `com.configdirector.sdk` subsystem.
- Support for iOS 15, iPadOS 15, macOS 12, tvOS 15 and watchOS 8, built in Swift 6 language mode
  under strict concurrency, with every public type `Sendable`.
