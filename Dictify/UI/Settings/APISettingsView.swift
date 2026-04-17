import SwiftUI

struct APISettingsView: View {
    @EnvironmentObject var appState: AppState
    let showMissingGroqAPIKeyWarning: Bool
    @State private var apiKey = ""
    @State private var testResult: TestResult?
    @State private var isTesting = false
    @State private var didSaveAPIKey = false
    @State private var saveError: String?

    enum TestResult {
        case success
        case failure(String)
    }

    var body: some View {
        Form {
            Section("Groq API Key") {
                if shouldShowMissingKeyWarning {
                    Label("Groq API key is required before dictation can transcribe.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                SecureField("Enter your Groq API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save Key") {
                        saveError = nil
                        if let km = appState.keychainManager {
                            didSaveAPIKey = km.saveAPIKey(apiKey)
                            appState.refreshAPIKeyStatus()
                            if didSaveAPIKey {
                                apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            } else {
                                saveError = "Could not save key"
                            }
                        } else {
                            didSaveAPIKey = false
                            saveError = "Keychain unavailable"
                        }
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Test Connection") {
                        testConnection()
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !appState.hasAPIKeyConfigured)

                    if isTesting {
                        ProgressView()
                            .scaleEffect(0.7)
                    }

                    if let result = testResult {
                        switch result {
                        case .success:
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        case .failure(let msg):
                            Label(msg, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }

                    if didSaveAPIKey && testResult == nil {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else if let saveError {
                        Label(saveError, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Text("Get your API key from [console.groq.com](https://console.groq.com)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                    Text("Your API key is stored securely in Apple Keychain and never leaves your Mac.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Models") {
                LabeledContent("Transcription") {
                    Text(Constants.API.whisperModel)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Refinement") {
                    Text(Constants.API.llamaModel)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Section("API Endpoints") {
                LabeledContent("Base URL") {
                    Text(Constants.API.baseURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            appState.refreshAPIKeyStatus()
            if let key = appState.keychainManager?.getAPIKey() {
                apiKey = key
                didSaveAPIKey = !key.isEmpty
            }
        }
        .onDisappear {
            // Don't leave the plaintext key sitting in view state memory when
            // the user closes Settings. The Keychain remains the source of truth.
            apiKey = ""
            testResult = nil
            saveError = nil
        }
    }

    private var shouldShowMissingKeyWarning: Bool {
        showMissingGroqAPIKeyWarning
            && !didSaveAPIKey
            && !appState.hasAPIKeyConfigured
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        guard let km = appState.keychainManager else {
            isTesting = false
            return
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            let didSave = km.saveAPIKey(apiKey)
            appState.refreshAPIKeyStatus()
            if didSave {
                apiKey = trimmedKey
                didSaveAPIKey = true
            } else if !appState.hasAPIKeyConfigured {
                testResult = .failure("Could not save key")
                isTesting = false
                return
            }
        }

        Task {
            do {
                let client = GroqClient(keychainManager: km)
                guard let url = URL(string: Constants.API.chatCompletionEndpoint) else {
                    throw URLError(.badURL)
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                let body: [String: Any] = [
                    "model": Constants.API.llamaModel,
                    "messages": [["role": "user", "content": "Hi"]],
                    "max_tokens": 5
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let _ = try await client.performRequest(request)

                await MainActor.run {
                    testResult = .success
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = .failure(error.localizedDescription)
                    isTesting = false
                }
            }
        }
    }
}
