# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases take their notes from this file, so the section for a version has to exist before that
version can be tagged. See [Releasing](CONTRIBUTING.md#releasing).

## [Unreleased]

## [1.1.0] - 2026-09-02

### Changed

- A `baseURL` whose path has no trailing slash, such as `https://proxy.example.com/configdirector`,
  now keeps that path when the SDK builds its endpoints. It used to resolve relative to the parent,
  dropping the last path component.
- In `.polling` mode, a transient failure on the first fetch of `initialize(context:)` or
  `updateContext(_:)` no longer returns early with an error. The context is applied, polling
  continues on the interval, and the call waits for the first successful poll up to the timeout,
  the way `.streaming` mode already behaved. A `.oneTime` client, which never retries, still
  reports the failure and keeps the previous context.
- `ConsoleLogger` writes debug messages as private, since they carry config values. They are shown
  in full while a debugger is attached and redacted from the unified log otherwise. Warnings and
  errors are still public.
- Reconnection delays in `.streaming` mode are spread out with jitter, and a connection that opens
  but delivers nothing no longer resets the backoff.

### Fixed

- A `values(for:default:)` stream now falls back to its default when a full config update no
  longer carries its config. It used to keep yielding the last value it had seen.
- Passing `.infinity` as `timeout` or `pollingInterval` no longer traps.
- `updateContext(_:)` calls that overlap, or that race with the reconnection performed when the
  app returns to the foreground, now apply in the order they were made. The last one made is the
  one that wins.
- `.ready` is no longer published before the new context is in effect when config state arrives
  on the heels of the connection opening.
- In `.polling` mode, an `updateContext(_:)` after an unrecoverable error now logs that error
  again instead of claiming the client will keep retrying, and the network is left alone when
  `pauseNetwork()` or `close()` is called while a connection attempt is in flight.
- The `Last-Event-ID` header is omitted after the server resets the event id to empty, as the
  server-sent events specification requires.
- A rejected response's body is cut to 200 characters in the error message.
- Telemetry no longer attributes an evaluation to the context it was not made against. Reading a
  config immediately after `updateContext(_:)` returned could be reported in the batch belonging to
  the previous context, because the collector was told about the new context in a detached task
  that had not necessarily run yet.

## [1.0.0] - 2026-08-30

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
