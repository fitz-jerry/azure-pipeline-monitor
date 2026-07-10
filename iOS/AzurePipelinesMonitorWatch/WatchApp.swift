import SwiftUI

@main
struct AzurePipelinesMonitorWatchApp: App {
    @StateObject private var config = AppConfig.shared
    @StateObject private var viewModel = WatchPipelinesViewModel()

    init() {
        WatchConnectivityReceiver.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchPipelineListView()
                .environmentObject(config)
                .environmentObject(viewModel)
        }
    }
}
