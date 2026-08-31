import ConfigDirector
import SwiftUI

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
