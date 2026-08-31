# ConfigDirector sample apps

Four SwiftUI apps showing how to use the ConfigDirector Swift client SDK: each reads a handful of
configs and re-renders as their values change.

[**ConfigDirectorSample**](ConfigDirectorSample) covers iOS and iPadOS as one universal target
rather than an iPhone app and an iPad app. The screen follows the horizontal size class: compact
stacks the configs and the context in a single list, regular moves the context into its own column
beside them. That covers iPad, an iPad Split View slice wide enough to be regular, and a landscape
iPhone Pro Max.

[**ConfigDirectorSampleMac**](ConfigDirectorSampleMac) covers macOS, in an `HSplitView` so the
divider between the context and the configs is draggable the way a Mac window should be. It is
sandboxed, and the sandbox is why the target turns on outgoing network connections — without that
entitlement the client cannot reach the server at all.

[**ConfigDirectorSampleTV**](ConfigDirectorSampleTV) covers tvOS, in a fixed two-column layout
rather than a list. tvOS moves focus with the remote and plain text rows do not take focus, so a
scrolling list would be unreachable; the five configs fit a 1080p screen without scrolling, and the
picker is the one thing that needs to be focusable.

[**ConfigDirectorSampleWatch**](ConfigDirectorSampleWatch) covers watchOS, standalone with no
companion iPhone app. One scrolling list, readiness in the navigation title where there is room for
it, and the context picker on the separate screen watchOS gives a `Picker` by default.

Everything that touches the SDK lives in [Shared](Shared) and compiles into both:
[the build-time settings](Shared/SampleConfiguration.swift), and
[the views](Shared/ConfigViews.swift), where `values(for:)` drives a SwiftUI view. Each app adds
only its entry point and its own layout, so the two differ in presentation and not in how they use
the SDK.

## How they depend on the SDK

The project adds ConfigDirector the way your own app would — as a released Swift package, resolved
from a version rather than from a path:

```
https://github.com/ConfigDirector/swift-sdk.git
```

In Xcode that is **File → Add Package Dependencies…**, pasting that URL and taking the default
*Up to Next Major Version*. In a `Package.swift` it is:

```swift
dependencies: [
    .package(url: "https://github.com/ConfigDirector/swift-sdk.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [.product(name: "ConfigDirector", package: "swift-sdk")]
    ),
]
```

Either way the module you import is `ConfigDirector`, which is what
[Shared/SampleConfiguration.swift](Shared/SampleConfiguration.swift) and
[Shared/ConfigViews.swift](Shared/ConfigViews.swift) do. Nothing in these apps depends on living
inside the SDK's repository.

## Running them

1. Copy the example config and fill in the client SDK key from your ConfigDirector dashboard:

   ```sh
   cp Config.local.example.xcconfig Config.local.xcconfig
   ```

2. Open the project, pick the `ConfigDirectorSample`, `ConfigDirectorSampleMac`,
   `ConfigDirectorSampleTV` or `ConfigDirectorSampleWatch` scheme, and run it on your Mac, a
   simulator or a device:

   ```sh
   open ConfigDirectorSample.xcodeproj
   ```

   Xcode fetches the SDK on first open, so that one needs a network connection.

`Config.local.xcconfig` is git-ignored, and all four apps read the same copy of it. Its values reach
them through the `Info.plist` and are read back with `Bundle.main.object(forInfoDictionaryKey:)`,
so nothing has to be committed. Without it each app builds and runs, and says it has no SDK
key.

Alongside the key it carries the context the configs are evaluated against:
`CONFIGDIRECTOR_USER_ID`, `CONFIGDIRECTOR_USER_NAME` and `CONFIGDIRECTOR_USER_ROLE` (sent as the
`role` trait). Leave them empty and the configs are evaluated without a context.

The Context picker switches between that configured user, a built-in beta tester carrying a
`role` trait, and an anonymous context. Each switch calls `updateContext`, which reconnects and
re-evaluates every config against the new identity — the way to watch a targeting rule take effect
without rebuilding.

## Building them against a local SDK checkout

Contributors to the SDK need the opposite of the above: the same four apps compiled against the
working tree, so a breaking API change fails here instead of reaching someone's app.

[ConfigDirectorSample-Local.xcworkspace](ConfigDirectorSample-Local.xcworkspace) is that. It holds
the sample project alongside the SDK's package root, and a local package in a workspace wins over a
remote dependency with the same identity — so every target builds against `../Sources` and nothing
is fetched. The targets, schemes and settings are the same ones; only where `ConfigDirector` comes
from changes.

```sh
open ConfigDirectorSample-Local.xcworkspace
```

This is what CI and the pre-push hook build. See
[Contributing](../CONTRIBUTING.md#building-them-against-this-checkout) for the details.

## What they show

All four apps read the keys of the ConfigDirector sample project — `temporary-feature-flag`,
`permanent-kill-switch`, `integer-config`, `day-of-the-week-config` and `json-value-config`.
Pointing them at a project without them is fine: each config falls back to the default value passed
alongside its key, which is what the screen shows until the client is ready.

Every default differs from the value the server sends, so a value on screen that matches its
default means the config did not resolve.

`json-value-config` is read with a `String` default, which serves the raw JSON document. The SDK
also decodes a JSON config into any `Decodable` type through
`client.value(for:as:default:)`.

All four connect in streaming mode, so a value changed in the ConfigDirector dashboard appears
on screen without restarting them.
