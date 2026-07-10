import SwiftUI

/// The two action sheets a pipeline can present. Shared by the list and the
/// detail screen so both drive the exact same flows.
enum PipelineActionSheet: Identifiable {
    case run(RunRef)
    case decide(ApprovalRef, Bool)

    var id: String {
        switch self {
        case .run(let r): return "run-\(r.definitionID)"
        case .decide(let a, let approve): return "decide-\(a.approvalID)-\(approve)"
        }
    }
}

extension View {
    /// Presents the Run / Approve / Reject sheet for `item`, wired to `viewModel`.
    func pipelineActionSheet(_ item: Binding<PipelineActionSheet?>,
                             viewModel: PipelinesViewModel) -> some View {
        sheet(item: item) { sheet in
            switch sheet {
            case .run(let ref):
                RunPipelineSheet(ref: ref) { branch in
                    await viewModel.run(ref: ref, branch: branch)
                }
            case .decide(let ref, let approve):
                ApprovalDecisionSheet(ref: ref, approve: approve) { comment in
                    await viewModel.decide(ref: ref, approve: approve, comment: comment)
                }
            }
        }
    }
}
