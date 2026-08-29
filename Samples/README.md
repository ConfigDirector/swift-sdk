# ConfigDirector iOS sample app

A single-screen SwiftUI app showing how to use the ConfigDirector Swift client SDK: it reads a
handful of configs and re-renders as their values change.

It is three files in [ConfigDirectorSample](ConfigDirectorSample):
[the app itself](ConfigDirectorSample/ConfigDirectorSampleApp.swift), which owns one client for the
life of the process; [the screen](ConfigDirectorSample/ContentView.swift), where `values(for:)`
drives a SwiftUI view; and [the build-time settings](ConfigDirectorSample/SampleConfiguration.swift).

## Running it

1. Copy the example config and fill in the client SDK key from your ConfigDirector dashboard:

   ```sh
   cp Config.local.example.xcconfig Config.local.xcconfig
   ```

2. Open the project and run it on a simulator or a device:

   ```sh
   open ConfigDirectorSample.xcodeproj
   ```

`Config.local.xcconfig` is git-ignored. Its values reach the app through the `Info.plist` and are
read back with `Bundle.main.object(forInfoDictionaryKey:)`, so nothing has to be committed. Without
it the app builds and runs, and says it has no SDK key.

Alongside the key it carries the context the configs are evaluated against:
`CONFIGDIRECTOR_USER_ID`, `CONFIGDIRECTOR_USER_NAME` and `CONFIGDIRECTOR_USER_ROLE` (sent as the
`role` trait). Leave them empty and the configs are evaluated without a context.

The picker under Context switches between that configured user, a built-in beta tester carrying a
`role` trait, and an anonymous context. Each switch calls `updateContext`, which reconnects and
re-evaluates every config against the new identity — the way to watch a targeting rule take effect
without rebuilding.

The project references the SDK as a local Swift package pointing at this checkout, so a breaking
API change fails the sample's build rather than shipping.

## What it shows

The app reads the keys of the ConfigDirector sample project — `temporary-feature-flag`,
`permanent-kill-switch`, `integer-config`, `day-of-the-week-config` and `json-value-config`.
Pointing it at a project without them is fine: each config falls back to the default value passed
alongside its key, which is what the screen shows until the client is ready.

Every default differs from the value the server sends, so a value on screen that matches its
default means the config did not resolve.

`json-value-config` is read with a `String` default, which serves the raw JSON document. The SDK
also decodes a JSON config into any `Decodable` type through
`client.value(for:as:default:)`.

## Until the transports land

The SDK currently ships a stub transport that serves a fixed config set, so the app shows those
values and never reaches a server. The stub serves the same keys the sample project does, so this
screen looks the same once the real transports are hooked up.
