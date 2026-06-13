import SwiftUI

struct AboutSettingsView: View {
    @State private var isBuildingBundle = false
    @State private var lastBundle: String?
    @State private var statusMessage: String?

    var body: some View {
        SettingsScaffold {
            identityCard

            SettingsSectionLabel(text: "Credits")
            creditsCard

            SettingsSectionLabel(text: "Feedback & Support")
            feedbackCard

            SettingsSectionLabel(text: "Diagnostics")
            diagnosticsCard

            Text("\u{00A9} 2026 Sunil Aleti")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
        }
    }

    // MARK: Identity

    private var identityCard: some View {
        SettingsCard {
            HStack(spacing: 16) {
                AppIconImage(size: 60, cornerRadius: 14)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dictify")
                        .font(.system(size: 22, weight: .bold))
                    Text("Intelligent Voice-to-Text for macOS")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("Version \(appVersion)")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(20)
        }
    }

    // MARK: Credits

    private var creditsCard: some View {
        SettingsCard {
            SettingsRow("Powered by") {
                Text("Groq · Whisper + Llama")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Feedback

    private var feedbackCard: some View {
        SettingsCard {
            SettingsRow("Send feedback or report an issue") {
                Link(destination: feedbackURL) {
                    Label(feedbackEmail, systemImage: "envelope")
                        .font(.system(size: 13))
                }
            }
        }
    }

    // MARK: Diagnostics

    private var diagnosticsCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Something went wrong? Logs are redacted — no API keys or dictated text are included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    if isBuildingBundle {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                .controlSize(.small)
                .disabled(isBuildingBundle)

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
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
