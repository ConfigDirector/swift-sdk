import ConfigDirector
import SwiftUI

/// The keys below are the ones in the ConfigDirector sample project. Against a project without
/// them, each config falls back to the default value passed alongside its key.
struct ContentView: View {
    let client: ConfigDirectorClient

    @State private var isReady = false
    @State private var context: ConfigDirectorContext?
    @State private var selectedUser = SampleUser.configured

    var body: some View {
        List {
            Section {
                ConfigRow("temporary-feature-flag", default: false)
                ConfigRow("permanent-kill-switch", default: true)
                ConfigRow("integer-config", default: 10)
                ConfigRow("day-of-the-week-config", default: "Friday")
                ConfigRow("json-value-config", default: "{}")
            } header: {
                HStack {
                    Text("Configs")
                    Spacer()
                    Text(isReady ? "Ready" : "Connecting…")
                        .foregroundColor(isReady ? .green : .secondary)
                }
            }

            Section("Context") {
                Picker("User", selection: userSelection) {
                    ForEach(SampleUser.allCases) { user in
                        Text(user.label).tag(user)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                ContextSummary(context: context)
            }
        }
        .environment(\.configDirectorClient, client)
        .task {
            // Subscribed before the current state is read, so an update landing in between is
            // buffered rather than missed.
            let events = client.events
            isReady = client.isReady
            context = client.context

            for await event in events {
                switch event {
                case .ready:
                    isReady = true
                case let .contextUpdated(updated):
                    context = updated
                default:
                    break
                }
            }
        }
    }

    private var userSelection: Binding<SampleUser> {
        Binding(
            get: { selectedUser },
            set: { user in
                selectedUser = user
                Task { await client.updateContext(user.context) }
            }
        )
    }
}

/// One config, read as the type its default value determines. It shows the current value and
/// updates whenever that value changes, whether from an edit in the dashboard or a context update.
struct ConfigRow<Value: ConfigValue & CustomStringConvertible>: View {
    @Environment(\.configDirectorClient) private var client

    private let configKey: String
    private let defaultValue: Value

    @State private var value: Value

    init(_ configKey: String, default defaultValue: Value) {
        self.configKey = configKey
        self.defaultValue = defaultValue
        _value = State(initialValue: defaultValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(configKey)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
            Text(value.description)
                .font(.body)
        }
        .padding(.vertical, 2)
        .task(id: configKey) {
            guard let client else { return }

            for await updated in client.values(for: configKey, default: defaultValue) {
                value = updated
            }
        }
    }
}

/// The context the configs above were evaluated against.
struct ContextSummary: View {
    let context: ConfigDirectorContext?

    var body: some View {
        if let context {
            VStack(alignment: .leading, spacing: 4) {
                field("id", context.id)
                field("name", context.name)
                field("traits", context.traits.map(Self.describe))
            }
            .padding(.vertical, 2)
        } else {
            Text("No context — configs are evaluated without one.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private func field(_ label: String, _ value: String?) -> some View {
        Text("\(label): \(value ?? "—")")
            .font(.system(.caption, design: .monospaced))
    }

    private static func describe(_ traits: [String: ConfigDirectorContext.TraitValue]) -> String {
        traits
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }
}

extension EnvironmentValues {
    @Entry var configDirectorClient: ConfigDirectorClient?
}
