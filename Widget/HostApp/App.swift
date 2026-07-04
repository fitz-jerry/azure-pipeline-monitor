import SwiftUI

// Minimal host app: WidgetKit requires the widget extension to live inside an
// app bundle. All pipeline data comes from the AzurePipelinesMonitor menu bar
// app; this window just explains that.
@main
struct AzurePipelinesWidgetApp: App {
    var body: some Scene {
        Window("Azure Pipelines Widget", id: "main") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Azure Pipelines Widget").font(.title2).bold()
                Text("""
                This app hosts the desktop widget. To add it, right-click the \
                desktop and choose Edit Widgets, then search for “Azure Pipelines”.

                The widget shows data collected by the Azure Pipelines Monitor \
                menu bar app, which must be running and configured. You can close \
                this window — the widget keeps working.
                """)
                .frame(maxWidth: 420, alignment: .leading)
            }
            .padding(24)
        }
        .windowResizability(.contentSize)
    }
}
