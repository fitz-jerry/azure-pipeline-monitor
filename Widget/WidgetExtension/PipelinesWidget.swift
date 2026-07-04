import WidgetKit
import SwiftUI

// MARK: - Snapshot written by the menu bar app

struct Snapshot: Codable {
    struct Pipeline: Codable, Identifiable {
        let project: String
        let name: String
        let state: String
        let detail: String
        let when: Date?
        var id: String { "\(project)#\(name)" }
    }
    let updated: Date
    let pipelines: [Pipeline]
}

func loadSnapshot() -> Snapshot? {
    // Inside the widget sandbox ~ resolves to the container; the menu bar app
    // writes the snapshot to this relative path in both the real home and the
    // container, so either way this finds it.
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AzurePipelinesMonitor/status.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(Snapshot.self, from: data)
}

// MARK: - Timeline

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, snapshot: loadSnapshot()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let snapshot = loadSnapshot()
        // No snapshot yet (widget freshly added, menu bar app fills the
        // container within a minute) — retry soon instead of the normal cadence.
        let interval: TimeInterval = snapshot == nil ? 60 : 300
        completion(Timeline(entries: [Entry(date: .now, snapshot: snapshot)],
                            policy: .after(Date().addingTimeInterval(interval))))
    }
}

// MARK: - Presentation helpers

func stateColor(_ state: String) -> Color {
    switch state {
    case "succeeded": return .green
    case "failed": return .red
    case "running": return .blue
    case "waitingApproval": return .orange
    case "canceled": return .gray
    default: return .secondary
    }
}

func stateSymbol(_ state: String) -> String {
    switch state {
    case "succeeded": return "checkmark.circle.fill"
    case "failed": return "xmark.circle.fill"
    case "running": return "arrow.triangle.2.circlepath.circle.fill"
    case "waitingApproval": return "hand.raised.circle.fill"
    case "canceled": return "stop.circle.fill"
    default: return "questionmark.circle"
    }
}

// Worst-first, so the most urgent state drives the small widget.
func overallState(_ pipelines: [Snapshot.Pipeline]) -> String {
    let order = ["failed", "waitingApproval", "running", "canceled", "succeeded"]
    for state in order where pipelines.contains(where: { $0.state == state }) {
        return state
    }
    return "other"
}

// MARK: - Views

struct PipelinesWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: Entry

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .systemSmall:
                SmallView(snapshot: snapshot)
            case .systemLarge:
                ListView(snapshot: snapshot, maxRows: 14)
            default:
                ListView(snapshot: snapshot, maxRows: 5)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "cursorarrow.click.badge.clock")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("No data yet")
                    .font(.headline)
                Text("Run the Azure Pipelines Monitor menu bar app")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

struct StaleBadge: View {
    let updated: Date

    var isStale: Bool { Date().timeIntervalSince(updated) > 600 }

    var body: some View {
        HStack(spacing: 3) {
            if isStale {
                Image(systemName: "exclamationmark.arrow.circlepath")
            }
            Text(updated, style: .relative)
        }
        .font(.caption2)
        .foregroundStyle(isStale ? .orange : .secondary)
    }
}

struct SmallView: View {
    let snapshot: Snapshot

    var body: some View {
        let overall = overallState(snapshot.pipelines)
        let failed = snapshot.pipelines.filter { $0.state == "failed" }.count
        let waiting = snapshot.pipelines.filter { $0.state == "waitingApproval" }.count
        let running = snapshot.pipelines.filter { $0.state == "running" }.count
        let succeeded = snapshot.pipelines.filter { $0.state == "succeeded" }.count

        VStack(spacing: 6) {
            Image(systemName: stateSymbol(overall))
                .font(.system(size: 34))
                .foregroundStyle(stateColor(overall))
            VStack(spacing: 2) {
                if failed > 0 { CountRow(count: failed, label: "failing", color: .red) }
                if waiting > 0 { CountRow(count: waiting, label: "need approval", color: .orange) }
                if running > 0 { CountRow(count: running, label: "running", color: .blue) }
                CountRow(count: succeeded, label: "passing", color: .green)
            }
            StaleBadge(updated: snapshot.updated)
        }
    }
}

struct CountRow: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text("\(count)").bold().foregroundStyle(color)
            Text(label).foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

struct ListView: View {
    let snapshot: Snapshot
    let maxRows: Int

    var body: some View {
        let multiProject = Set(snapshot.pipelines.map(\.project)).count > 1
        let shown = Array(snapshot.pipelines.prefix(maxRows))
        let hidden = snapshot.pipelines.count - shown.count

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Azure Pipelines").font(.headline)
                Spacer()
                StaleBadge(updated: snapshot.updated)
            }
            Divider()
            ForEach(shown) { pipeline in
                HStack(spacing: 6) {
                    Image(systemName: stateSymbol(pipeline.state))
                        .font(.caption)
                        .foregroundStyle(stateColor(pipeline.state))
                    Text(multiProject ? "\(pipeline.project) / \(pipeline.name)" : pipeline.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Text(pipeline.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if hidden > 0 {
                Text("+ \(hidden) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Widget definition

@main
struct PipelinesWidgetBundle: WidgetBundle {
    var body: some Widget {
        PipelinesWidget()
    }
}

struct PipelinesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AzurePipelinesStatus", provider: Provider()) { entry in
            PipelinesWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Azure Pipelines")
        .description("Latest run status of your Azure DevOps pipelines.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
