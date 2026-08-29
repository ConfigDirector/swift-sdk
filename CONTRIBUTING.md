# Contributing

## Development

Requires Xcode 26 or newer, which carries the Swift 6.3 toolchain the package is built with. The
package itself has no dependencies.

The linters are separate tools, installed once per machine:

```bash
brew install swiftlint swiftformat
```

## Building and testing

```bash
swift build
swift test
swiftformat .
swiftlint lint --quiet
```

Both linters read their configuration from the package root, so they need no arguments.
`swiftformat .` rewrites files in place; pass `--lint` instead to check without rewriting, which is
what a CI job should run.

`swift test` output is verbose enough to bury a failure. To see only what broke:

```bash
swift test 2>&1 | grep '✘'
```

Run a single suite or a single test with `--filter`, which takes a regular expression matched
against `SuiteName/testName`:

```bash
swift test --filter ConfigValueParserTests
swift test --filter truncatesAFloatServedToAnIntegerDefault
swift test --filter 'ConfigValueParserTests/rejects'
```

`swift build --build-tests` type-checks the test target without running it.

### Other platforms

The tests run on the macOS host only. The SDK also ships for iOS, tvOS, and watchOS, so a change
that touches anything platform-specific should be compiled for each of them:

```bash
swift build --sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -Xswiftc -target -Xswiftc arm64-apple-ios15.0
swift build --sdk "$(xcrun --sdk appletvos --show-sdk-path)" \
  -Xswiftc -target -Xswiftc arm64-apple-tvos15.0
swift build --sdk "$(xcrun --sdk watchos --show-sdk-path)" \
  -Xswiftc -target -Xswiftc arm64_32-apple-watchos8.0
```

These catch what the macOS build cannot, such as an API that is isolated to the main actor on one
platform and not another.

## Tests

Tests are written with [Swift Testing](https://developer.apple.com/documentation/testing), not
XCTest.

A test is only worth having if it fails when the behavior it covers breaks. Write it before the
implementation and watch it fail for the right reason; if it was written afterwards, break the
implementation on purpose, confirm that test — and not some unrelated one — fails, then put the
implementation back.

That check is not a formality. It is how we found that the watch-stream de-duplication test was
passing for the wrong reason: the stream buffers only the newest value, so it dropped the duplicate
emission before the test could observe it, and the test still passed with de-duplication removed
entirely.

Tests of the client cover it through its public API against a stubbed ConfigDirector server, with
nothing inside the SDK replaced: `StubURLProtocol` scripts the HTTP responses, and `ClientFixture`
gives each test a base URL of its own so a client still winding down cannot consume the response the
next test queued. Reach for a fake transport only for something the wire genuinely cannot express.

Watch streams and event streams need particular care. `withTimeout` cancels the task it wraps, and
cancelling a task that is awaiting an `AsyncStream` terminates that stream, so a timeout cannot be
used to assert that nothing was emitted — the stream is dead afterwards either way. Collect the
whole sequence of emissions and assert on it instead.

## CI and the pre-push hook

[.github/workflows/ci.yml](.github/workflows/ci.yml) runs on every branch and pull request: build
and test, both linters, a compile for iOS, tvOS and watchOS, and a build of the sample app.

The same jobs run locally as a `pre-push` hook, in that order and with the same commands. Wire it
up once per clone:

```bash
git config core.hooksPath .githooks
```

It checks the working tree rather than the commits being pushed, so uncommitted changes are
included. Bypass it for a single push with `git push --no-verify`.

The cheap checks run first, so an unformatted file fails in seconds instead of after the platform
matrix. It needs SwiftLint and SwiftFormat on `PATH` and refuses to run without them, rather than
silently skipping a check CI will fail on.

## Sample app

[Samples/ConfigDirectorSample.xcodeproj](Samples/ConfigDirectorSample.xcodeproj) is an iOS app that
consumes the SDK as a local Swift package, so a breaking API change fails its build. See
[Samples/README.md](Samples/README.md) for how to point it at your own ConfigDirector project.

Building it needs no SDK key — without one the app says so and runs anyway:

```bash
xcodebuild -project Samples/ConfigDirectorSample.xcodeproj \
  -scheme ConfigDirectorSample -destination 'generic/platform=iOS Simulator' build
```

The `.xcodeproj` is written by hand rather than generated, so it needs no extra tooling to open. It
uses a file-system-synchronized group, which means adding or removing a source file under
`Samples/ConfigDirectorSample` does not touch the project file at all.
