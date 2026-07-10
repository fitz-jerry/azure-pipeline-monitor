import SwiftUI

@main
struct AzurePipelinesMonitorApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var config = AppConfig.shared
    @StateObject private var viewModel = PipelinesViewModel()

    init() {
        // Must register the BG task handler before launch completes.
        BackgroundRefresh.register()
        NotificationService.shared.requestAuthorization()
        PhoneConnectivity.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            PipelineListView()
                .environmentObject(config)
                .environmentObject(viewModel)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                BackgroundRefresh.schedule()
            }
        }
    }
}
