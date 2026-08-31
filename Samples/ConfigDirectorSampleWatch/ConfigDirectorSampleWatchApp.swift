import ConfigDirector
import SwiftUI

@main
struct ConfigDirectorSampleWatchApp: App {
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
        ScrollView {
            Text("No client SDK key. Put one in Config.local.xcconfig and run the app again.")
                .multilineTextAlignment(.center)
                .padding()
        }
    }
}
