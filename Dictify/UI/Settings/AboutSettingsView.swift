import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // App Icon
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.blue.gradient)
                    .frame(width: 100, height: 100)
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.white)
            }
            .shadow(color: .blue.opacity(0.3), radius: 12, y: 4)

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

            Spacer()

            Text("\u{00A9} 2026 Sunil Aleti")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

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
