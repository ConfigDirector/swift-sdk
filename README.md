# ConfigDirector Swift SDK

The Swift client SDK for ConfigDirector. It evaluates your feature flags and remote configs against
a user context, keeps them current as they change in the dashboard, and hands SwiftUI values it can
re-render from.

```swift
let client = try ConfigDirectorClient(clientSDKKey: "YOUR-CLIENT-SDK-KEY")
await client.initialize(context: ConfigDirectorContext(id: "user-123"))

let darkMode = client.value(for: "dark-mode", default: false)
```

## Requirements

| Platform      | Minimum |
| ------------- | ------- |
| iOS / iPadOS  | 15.0    |
| macOS         | 12.0    |
| tvOS          | 15.0    |
| watchOS       | 8.0     |

Swift 6.0 or newer. The package builds in Swift 6 language mode under strict concurrency, and every
public type is `Sendable`.

## Installation

In Xcode, **File → Add Package Dependencies**, then enter
`https://github.com/ConfigDirector/swift-sdk`.

In a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ConfigDirector/swift-sdk", from: "0.1.0"),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [.product(name: "ConfigDirector", package: "swift-sdk")]
    ),
]
```

## Creating the client

Create one client and keep it for the life of the process. It is thread-safe, and creating several
means several connections to the server.

```swift
let client = try ConfigDirectorClient(clientSDKKey: "YOUR-CLIENT-SDK-KEY")
await client.initialize(context: ConfigDirectorContext(id: "user-123", name: "Ada"))
```

Until `initialize` completes, every config evaluates to the default you pass alongside its key, so
there is no state in which a read fails or blocks. Call `close()` when you are done with the client.

## Reading a config

`value(for:default:)` is synchronous, so it is safe to call from a SwiftUI `body`:

```swift
let darkMode  = client.value(for: "dark-mode", default: false)
let pageSize  = client.value(for: "page-size", default: 25)
let greeting  = client.value(for: "greeting", default: "Hello")
```

The default decides the type. `Bool`, `String`, `Int` and `Double` are supported out of the box; a
value the server cannot serve as the type you asked for falls back to your default rather than
trapping. Conform your own type to `ConfigValue` to read a config as it.

A config holding a JSON document decodes into any `Decodable`:

```swift
struct Theme: Decodable {
    let primary: String
}

let theme = client.value(for: "theme", as: Theme.self, default: Theme(primary: "#101010"))
```

## Following a config in SwiftUI

`values(for:default:)` returns an `AsyncStream` that yields the current value immediately and then
each time it changes — whether from an edit in the dashboard or a new context. Repeated identical
values are not re-emitted.

```swift
struct DarkModeToggle: View {
    let client: ConfigDirectorClient

    @State private var isOn = false

    var body: some View {
        Toggle("Dark mode", isOn: $isOn)
            .task {
                for await value in client.values(for: "dark-mode", default: false) {
                    isOn = value
                }
            }
    }
}
```

## Context

The context is who the configs are evaluated against. Targeting rules in the dashboard match on its
`id`, `name` and `traits`:

```swift
await client.updateContext(
    ConfigDirectorContext(
        id: "user-123",
        name: "Ada Lovelace",
        traits: ["plan": "pro", "seats": 12, "beta": true]
    )
)
```

`updateContext` reconnects and re-evaluates every config. Configs keep evaluating against the
previous context until that succeeds or times out, so values never blank out mid-switch. For a
signed-out user, `ConfigDirectorContext(isAnonymous: true)`.

## Connection modes

| Mode        | Behaviour                                                             |
| ----------- | --------------------------------------------------------------------- |
| `.streaming` | Holds a connection open and receives changes as they happen. Default. |
| `.polling`   | Re-fetches on a fixed interval, `pollingInterval` (default 60s).      |
| `.oneTime`   | Fetches at initialization and on context updates only.                |

```swift
let client = try ConfigDirectorClient(
    clientSDKKey: "YOUR-CLIENT-SDK-KEY",
    options: ConfigDirectorClientOptions(
        connection: ConnectionOptions(mode: .polling, pollingInterval: 300)
    )
)
```

Other `ConnectionOptions`: `timeout` (default 3s), `baseURL` for routing through a proxy, and
`pausesWhileBackgrounded` (default `true`), which drops the connection while the app is backgrounded
and restores it on return. That last one has no effect on macOS, where an app keeps running after it
leaves the foreground. To manage it yourself, set it to `false` and call `pauseNetwork()` and
`resumeNetwork()`.

## Logging

The SDK logs to the unified logging system under the `com.configdirector.sdk` subsystem, at `warn`
and above. Turn it up while integrating:

```swift
ConfigDirectorClientOptions(logger: ConsoleLogger(level: .debug))
```

Conform to `ConfigDirectorLogger` to route SDK logs into your own logging instead.

## Events

`client.events` publishes `ready`, `configsUpdated` and `contextUpdated`; `client.evaluations`
publishes every individual config evaluation, which is useful for debugging what a screen actually
read.

```swift
for await event in client.events {
    if case let .ready(reason) = event {
        print("ready after \(reason)")
    }
}
```

## Sample apps

[Samples](Samples) holds four apps built on this SDK — iOS/iPadOS, macOS, tvOS and watchOS — sharing
one set of SDK-facing code so they differ only in layout. See [Samples/README.md](Samples/README.md)
to point them at your own ConfigDirector project.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the repository layout, the checks that run on every push,
and how to install the pre-push hook.

## License

MIT. See [LICENSE](LICENSE).
