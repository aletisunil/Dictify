import SwiftUI

struct MenuBarPopover: View {
    @ObservedObject var appState: AppState
    let onSettingsClicked: () -> Void
    let onConfigureAPIClicked: () -> Void
    let onQuitClicked: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("Dictify")
                    .font(.headline)
                Spacer()
                statusBadge
            }
            .padding()

            if !appState.hasAPIKeyConfigured {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("API key is stored safely in Apple Keychain")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
            }

            Divider()

            if let statsStore = appState.statsStore {
                StatsStrip(statsStore: statsStore)
            }

            Divider()

            // Recent Transcriptions
            if let historyStore = appState.historyStore, !historyStore.records.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        Text("Recent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .padding(.top, 8)

                        ForEach(historyStore.records) { record in
                            TranscriptionRow(record: record)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 260)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "mic.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No transcriptions yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Hold fn to start dictating")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 40)
            }

            Divider()

            // Footer
            HStack {
                Button(action: onSettingsClicked) {
                    Label("Settings", systemImage: "gear")
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onQuitClicked) {
                    Text("Quit")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding()
        }
        .frame(width: 320, height: 400)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch appState.pipelineState {
        case .idle:
            if appState.hasAPIKeyConfigured {
                StatusBadge(label: "Ready", tint: .green)
            } else {
                Button(action: onConfigureAPIClicked) {
                    StatusBadge(label: "Configure Groq API", tint: .red)
                }
                .buttonStyle(.plain)
            }
        case .recording:
            StatusBadge(label: "Recording", tint: .red)
        case .transcribing, .refining, .inserting:
            StatusBadge(label: "Processing", tint: .orange)
        default:
            EmptyView()
        }
    }
}

struct StatusBadge: View {
    let label: String
    let tint: Color

    var body: some View {
        Text(label)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.18))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }
}

struct StatsStrip: View {
    @ObservedObject var statsStore: StatsStore

    var body: some View {
        HStack(spacing: 0) {
            StatColumn(
                title: "Session",
                value: "\(statsStore.sessionWords)",
                detail: "words"
            )

            Divider()
                .padding(.vertical, 8)

            StatColumn(
                title: "Total",
                value: "\(statsStore.totalWords)",
                detail: "words"
            )

            Divider()
                .padding(.vertical, 8)

            StatColumn(
                title: "WPM",
                value: wpmValue,
                detail: "session / total"
            )
        }
        .frame(height: 58)
        .padding(.horizontal, 8)
    }

    private var wpmValue: String {
        let session = formatWPM(statsStore.sessionWPM)
        let total = formatWPM(statsStore.totalWPM)
        return "\(session) / \(total)"
    }

    private func formatWPM(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }
}

private struct StatColumn: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.primary)

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct TranscriptionRow: View {
    let record: TranscriptionRecord
    @State private var copied = false

    var body: some View {
        Button(action: copyText) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.refinedText)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                HStack {
                    Text(record.date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if copied {
                        Text("Copied!")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.refinedText, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}
