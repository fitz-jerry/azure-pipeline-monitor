import SwiftUI

struct ApprovalDecisionSheet: View {
    let ref: ApprovalRef
    let approve: Bool
    /// Called with the comment when the user confirms.
    let onDecide: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var comment = ""
    @State private var submitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Comment (optional)", text: $comment, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Comment")
                } footer: {
                    Text(approve
                         ? "Approves the pending environment check for \(ref.pipelineName)."
                         : "Rejects the pending environment check for \(ref.pipelineName).")
                }
            }
            .navigationTitle(approve ? "Approve" : "Reject")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(approve ? "Approve" : "Reject") { submit() }
                        .disabled(submitting)
                }
            }
        }
    }

    private func submit() {
        submitting = true
        Task {
            await onDecide(comment.trimmingCharacters(in: .whitespaces))
            dismiss()
        }
    }
}
