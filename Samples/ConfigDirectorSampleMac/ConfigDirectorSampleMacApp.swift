import ConfigDirector
import SwiftUI

@main
struct ConfigDirectorSampleMacApp: App {
    @State private var client = SampleConfiguration.makeClient()

    var body: some Scene {
        WindowGroup {
            if let client {
                ContentView(client: client)
                    .task {
                        await client.initialize(context: SampleConfiguration.context)
                    }
            } else {
                MissingSDKKeyView()
            }
        }
    }
}

struct MissingSDKKeyView: View {
    var body: some View {
        Text(
            """
            No client SDK key.

            Copy Config.local.example.xcconfig to Config.local.xcconfig, put your client SDK key \
            in it, and run the app again.
            """
        )
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(minWidth: 420, minHeight: 220)
    }
}
