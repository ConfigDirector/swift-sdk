# ConfigDirector sample apps

Two SwiftUI apps showing how to use the ConfigDirector Swift client SDK: each reads a handful of
configs and re-renders as their values change.

[**ConfigDirectorSample**](ConfigDirectorSample) covers iOS and iPadOS as one universal target
rather than an iPhone app and an iPad app. The screen follows the horizontal size class: compact
stacks the configs and the context in a single list, regular moves the context into its own column
beside them. That covers iPad, an iPad Split View slice wide enough to be regular, and a landscape
iPhone Pro Max.

[**ConfigDirectorSampleWatch**](ConfigDirectorSampleWatch) covers watchOS, standalone with no
companion iPhone app. One scrolling list, readiness in the navigation title where there is room for
it, and the context picker on the separate screen watchOS gives a `Picker` by default.

Everything that touches the SDK lives in [Shared](Shared) and compiles into both:
[the build-time settings](Shared/SampleConfiguration.swift), and
[the views](Shared/ConfigViews.swift), where `values(for:)` drives a SwiftUI view. Each app adds
only its entry point and its own layout, so the two differ in presentation and not in how they use
the SDK.

## Running them

1. Copy the example config and fill in the client SDK key from your ConfigDirector dashboard:

   ```sh
   cp Config.local.example.xcconfig Config.local.xcconfig
   ```

2. Open the project, pick the `ConfigDirectorSample` or `ConfigDirectorSampleWatch` scheme, and
   run it on a simulator or a device:

   ```sh
   open ConfigDirectorSample.xcodeproj
   ```

`Config.local.xcconfig` is git-ignored, and both apps read the same copy of it. Its values reach
them through the `Info.plist` and are read back with `Bundle.main.object(forInfoDictionaryKey:)`,
so nothing has to be committed. Without it either app builds and runs, and says it has no SDK
key.

Alongside the key it carries the context the configs are evaluated against:
`CONFIGDIRECTOR_USER_ID`, `CONFIGDIRECTOR_USER_NAME` and `CONFIGDIRECTOR_USER_ROLE` (sent as the
`role` trait). Leave them empty and the configs are evaluated without a context.

The Context picker switches between that configured user, a built-in beta tester carrying a
`role` trait, and an anonymous context. Each switch calls `updateContext`, which reconnects and
re-evaluates every config against the new identity — the way to watch a targeting rule take effect
without rebuilding.

The project references the SDK as a local Swift package pointing at this checkout, so a breaking
API change fails the samples' build rather than shipping.

## What they show

Both apps read the keys of the ConfigDirector sample project — `temporary-feature-flag`,
`permanent-kill-switch`, `integer-config`, `day-of-the-week-config` and `json-value-config`.
Pointing them at a project without them is fine: each config falls back to the default value passed
alongside its key, which is what the screen shows until the client is ready.

Every default differs from the value the server sends, so a value on screen that matches its
default means the config did not resolve.

`json-value-config` is read with a `String` default, which serves the raw JSON document. The SDK
also decodes a JSON config into any `Decodable` type through
`client.value(for:as:default:)`.

Both connect in streaming mode, so a value changed in the ConfigDirector dashboard appears on
screen without restarting them.
