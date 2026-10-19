import AppKit
import MemoirKit
import SwiftUI

/// Under the transcript once a call stops (DESIGN.md §4.8): the call is saved, then each pipeline step
/// with its progress — and what it made (Open Summary, Open Google Doc, Copy Link) when it's done.
struct PostCallBar: View {
    let model: AppModel
    let folder: URL

    private var key: String { folder.path }
    private var state: PipelineState? { model.pipelineStates[key] }
    private var steps: [PipelineStep] { model.pipeline?.steps ?? [] }
    private var busy: Bool { model.isBusy(folder) }

    /// Steps this call ran or will run.
    private var shown: [PipelineStep] {
        let planned = model.plannedSteps(folder)
        return steps.filter { state?.steps[$0.id] != nil || planned.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                StepChip(label: "Saved", status: .ok)
                    .help(folder.path)
                ForEach(shown) { step in
                    // Not in the state yet: waiting for another call's job to finish.
                    StepChip(label: step.label, status: state?.steps[step.id]?.status ?? .pending,
                             startedAt: state?.steps[step.id]?.startedAt, message: state?.steps[step.id]?.message)
                }
                Spacer(minLength: 8)
                if busy {
                    Button("Cancel") { model.cancelProcessing(folder) }
                } else {
                    results
                }
                actions
            }
            .controlSize(.small)

            if !busy, let (step, failed) = firstFailure {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(step.label) failed: \(failed.message ?? "see the log")")
                        .font(.caption).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button("Show Log") { NSWorkspace.shared.open(PipelineState.log(folder, step: step.id)) }
                    Button("Retry") { model.process(folder, steps: model.chosenSteps(for: folder)) }
                }
                .controlSize(.small)
            }
            if let lines = model.tooShort[key] {
                HStack(alignment: .firstTextBaseline) {
                    Text("Too short to process automatically (\(lines) line\(lines == 1 ? "" : "s")).")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Process Anyway") { model.process(folder, steps: model.chosenSteps(for: folder)) }
                }
                .controlSize(.small)
            }
            if let error = model.processingErrors[key] {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
            }
        }
    }

    private var firstFailure: (PipelineStep, StepState)? {
        for step in shown {
            if let s = state?.steps[step.id], s.status == .failed { return (step, s) }
        }
        return nil
    }

    /// What the finished steps made.
    @ViewBuilder private var results: some View {
        ForEach(shown) { step in
            if let s = state?.steps[step.id], s.status == .ok {
                if let link = s.url, let url = URL(string: link) {
                    Button("Open \(step.label)") { NSWorkspace.shared.open(url) }
                    Button("Copy Link") { model.copy(link) }
                } else if let output = s.outputs?.first {
                    Button("Open \(step.label)") { NSWorkspace.shared.open(folder.appendingPathComponent(output)) }
                }
            }
        }
    }

    private var actions: some View {
        Menu {
            ForEach(steps) { step in
                Button("Run \(step.label)") { model.run([step.id], on: folder, force: true) }
            }
            if !steps.isEmpty {
                Button("Run All Again") { model.run(model.chosenSteps(for: folder), on: folder, force: true) }
                Divider()
            }
            ForEach(steps.filter { FileManager.default.fileExists(atPath: PipelineState.log(folder, step: $0.id).path) }) { step in
                Button("Show \(step.label) Log") { NSWorkspace.shared.open(PipelineState.log(folder, step: step.id)) }
            }
            Button("Open Folder") { model.open(folder) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(busy)
        .help("Run steps again, logs, folder")
    }
}

/// ✓ Summary · ◌ Google Doc 0:42 · ✗ …
struct StepChip: View {
    let label: String
    let status: StepState.Status
    var startedAt: Date?
    var message: String?

    var body: some View {
        HStack(spacing: 4) {
            icon
            Text(label).font(.caption)
            if status == .running, let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(meetingClock(context.date.timeIntervalSince(startedAt)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .help(message ?? status.rawValue)
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.mini)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }
}
