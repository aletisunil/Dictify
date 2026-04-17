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

            Button("Show Onboarding Again") {
                AppDelegate.shared?.showOnboarding()
            }
            .controlSize(.regular)

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
}
