import SwiftUI

struct RunPipelineSheet: View {
    let ref: RunRef
    /// Called with the branch (nil = pipeline default) when the user taps Run.
    let onRun: (String?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var branch: String
    @State private var submitting = false

    init(ref: RunRef, onRun: @escaping (String?) async -> Void) {
        self.ref = ref
        self.onRun = onRun
        // Pre-fill with the last run's branch — but not PR merge refs
        // (refs/pull/…), which can't be queued directly.
        if let last = ref.lastBranch, !last.hasPrefix("refs/") {
            _branch = State(initialValue: last)
        } else {
            _branch = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Branch (empty = pipeline default)", text: $branch)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Branch")
                } footer: {
                    Text("Queues a new run in \(ref.project). Leave empty to use the pipeline's default branch.")
                }
            }
            .navigationTitle("Run “\(ref.pipelineName)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run") { submit() }
                        .disabled(submitting)
                }
            }
        }
    }

    private func submit() {
        submitting = true
        let trimmed = branch.trimmingCharacters(in: .whitespaces)
        Task {
            await onRun(trimmed.isEmpty ? nil : trimmed)
            dismiss()
        }
    }
}
