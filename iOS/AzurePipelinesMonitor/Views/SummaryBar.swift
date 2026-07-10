import SwiftUI

/// A pinned, glanceable count of pipeline states across all projects.
struct SummaryBar: View {
    let failing: Int
    let awaiting: Int
    let running: Int
    let passing: Int

    private var total: Int { failing + awaiting + running + passing }

    var body: some View {
        if total > 0 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(count: failing, label: "failing",
                         symbol: PipelineState.failed.symbolName, color: .red)
                    chip(count: awaiting, label: "awaiting",
                         symbol: PipelineState.waitingApproval.symbolName, color: .orange)
                    chip(count: running, label: "running",
                         symbol: PipelineState.running.symbolName, color: .blue)
                    chip(count: passing, label: "passing",
                         symbol: PipelineState.succeeded.symbolName, color: .green)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    @ViewBuilder
    private func chip(count: Int, label: String, symbol: String, color: Color) -> some View {
        if count > 0 {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                Text("\(count)")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text(label)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
        }
    }
}
