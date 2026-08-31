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
        NavigationView {
            List {
                Section("Configs") {
                    ConfigRow("temporary-feature-flag", default: false)
                    ConfigRow("permanent-kill-switch", default: true)
                    ConfigRow("integer-config", default: 10)
                    ConfigRow("day-of-the-week-config", default: "Friday")
                    ConfigRow("json-value-config", default: "{}")
                }

                Section("Context") {
                    Picker("User", selection: userSelection) {
                        ForEach(SampleUser.allCases) { user in
                            Text(user.label).tag(user)
                        }
                    }

                    ContextSummary(context: context)
                }
            }
            .navigationTitle(isReady ? "Ready" : "Connecting…")
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
