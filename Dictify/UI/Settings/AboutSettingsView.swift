import SwiftUI

struct AboutSettingsView: View {
    @State private var isBuildingBundle = false
    @State private var lastBundle: String?
    @State private var statusMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Space.xl) {
                // Hero — the real AppIcon, matching the Dock and sidebar.
                VStack(spacing: DS.Space.md) {
                    AppIconImage(size: 96, cornerRadius: 22)
                        .shadow(color: .appAccent.opacity(0.22), radius: 14, y: 4)

                    VStack(spacing: DS.Space.xs) {
                        Text("Dictify")
                            .font(.dsTitle)
                        Text("Intelligent Voice-to-Text for macOS")
                            .font(.dsBody)
                            .foregroundStyle(.secondary)
                        Text("Version \(appVersion)")
                            .font(.dsCaption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, DS.Space.xxl)

                // Credits + feedback card
                VStack(spacing: DS.Space.md) {
                    infoRow(label: "Powered by", value: "Groq — Whisper + GPT-OSS")
                    Divider().background(Color.appHairline)
                    HStack {
                        Text("Feedback & Support")
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Link(destination: feedbackURL) {
                            Label(feedbackEmail, systemImage: "envelope")
                                .font(.dsCaption)
                        }
                        .help("Send feedback or report an issue")
                    }
                }
                .dsCard()
                .frame(maxWidth: 420)

                diagnosticsSection
                    .frame(maxWidth: 420)

                Text("\u{00A9} 2026 Sunil Aleti")
                    .font(.dsCaption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, DS.Space.lg)
            }
            .frame(maxWidth: .infinity)
            .padding(DS.pageInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appWindowBackground)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.dsCaption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.dsCaption)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                Text("Diagnostics")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: DS.Space.sm) {
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
                .controlSize(.small)
                .disabled(isBuildingBundle)
            }

            if isBuildingBundle {
                ProgressView()
                    .controlSize(.small)
            } else if let statusMessage {
                Text(statusMessage)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Logs are redacted — no API keys or dictated text are included.")
                    .font(.dsCaption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
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
