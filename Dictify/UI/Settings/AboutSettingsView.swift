import SwiftUI

struct AboutSettingsView: View {
    @State private var isBuildingBundle = false
    @State private var lastBundle: String?
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // App Icon — the real AppIcon, matching the Dock and sidebar.
            AppIconImage(size: 100, cornerRadius: 24)
                .shadow(color: .appAccent.opacity(0.25), radius: 12, y: 4)

            // App Name and Version
            VStack(spacing: 4) {
                Text("Dictify")
                    .font(.title.bold())

                Text("Version \(appVersion)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Description
            Text("Intelligent Voice-to-Text for macOS")
                .font(.body)
                .foregroundStyle(.secondary)

            // Credits
            VStack(spacing: 4) {
                Text("Powered by")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("Groq — Whisper + Llama")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Feedback
            VStack(spacing: 6) {
                Text("Feedback & Support")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Link(destination: feedbackURL) {
                    Label(feedbackEmail, systemImage: "envelope")
                        .font(.caption)
                }
                .help("Send feedback or report an issue")
            }

            diagnosticsSection

            Spacer()

            Text("\u{00A9} 2026 Sunil Aleti")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color.appWindowBackground)
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        VStack(spacing: 8) {
            Text("Diagnostics")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Text("Something went wrong?\nLogs are redacted — no API keys or dictated text are included.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    Task { await copyLogs() }
                } label: {
                    Label("Copy Logs", systemImage: "doc.on.clipboard")
                }

                Button {
                    Task { await emailLogs() }
                } label: {
                    Label("Email Logs", systemImage: "paperplane")
                }
            }
            .font(.caption)
            .disabled(isBuildingBundle)

            if isBuildingBundle {
                ProgressView()
                    .controlSize(.small)
            } else if let statusMessage {
                Text(statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Diagnostics actions

    @MainActor
    private func makeBundle() async -> String {
        isBuildingBundle = true
        defer { isBuildingBundle = false }
        let bundle = await DiagnosticsBundle.build()
        lastBundle = bundle
        return bundle
    }

    private func copyLogs() async {
        let bundle = await makeBundle()
        DiagnosticsBundle.copyToPasteboard(bundle)
        statusMessage = "Logs copied to clipboard."
    }

    private func emailLogs() async {
        let bundle = await makeBundle()
        statusMessage = DiagnosticsBundle.email(bundle: bundle)
            ? nil
            : "Couldn't open Mail. Use Copy Logs instead."
    }

    // MARK: - Feedback

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private let feedbackEmail = "iam@sunilaleti.dev"

    private var feedbackURL: URL {
        let subject = "Dictify Feedback (v\(appVersion))"
        let encoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        return URL(string: "mailto:\(feedbackEmail)?subject=\(encoded)") ?? URL(string: "mailto:\(feedbackEmail)")!
    }
}
