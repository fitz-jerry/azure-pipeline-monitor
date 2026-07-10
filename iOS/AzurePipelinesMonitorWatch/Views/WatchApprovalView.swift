import SwiftUI

struct WatchApprovalView: View {
    let ref: ApprovalRef
    let approve: Bool
    @EnvironmentObject var viewModel: WatchPipelinesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var comment = ""
    @State private var submitting = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(ref.pipelineName)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                TextField("Comment (optional)", text: $comment)

                Button {
                    submit()
                } label: {
                    if submitting {
                        ProgressView()
                    } else {
                        Label(approve ? "Approve" : "Reject",
                              systemImage: approve ? "checkmark" : "xmark")
                            .frame(maxWidth: .infinity)
                    }
                }
                .tint(approve ? .green : .red)
                .disabled(submitting)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(approve ? "Approve" : "Reject")
    }

    private func submit() {
        submitting = true
        errorMessage = nil
        Task {
            let result = await viewModel.decide(ref: ref, approve: approve, comment: comment)
            submitting = false
            if let result, result.success {
                dismiss()
            } else {
                errorMessage = result?.body ?? "Couldn't submit — try again."
            }
        }
    }
}
