import SwiftUI

extension PipelineState {
    /// Tint used across the list, summary bar, detail, and the watch app.
    var color: Color {
        switch self {
        case .succeeded: return .green
        case .failed: return .red
        case .running: return .blue
        case .waitingApproval: return .orange
        case .canceled: return .secondary
        case .other: return .yellow
        }
    }
}
