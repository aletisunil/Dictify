import SwiftUI
import AVFoundation
import AppKit

// MARK: - Onboarding Pages

private enum OnboardingPage: Int, CaseIterable {
    case welcome = 0
    case features = 1
    case permissions = 2
    case apiKey = 3
    case completion = 4
}

// MARK: - Main Onboarding View

struct PermissionOnboardingView: View {
    @ObservedObject var permissionManager: PermissionManager
    var keychainManager: KeychainManager?
    let onAccessibilityPermissionRequest: () -> Void
    let onAPIKeySaved: () -> Void
    let onComplete: () -> Void

    @State private var currentPage: OnboardingPage = .welcome
    @State private var isRequestingAccessibilityPermission = false

    // API Key state
    @State private var apiKey = ""
    @State private var showKey = false
    @State private var didSaveKey = false
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Page content
            ZStack {
                switch currentPage {
                case .welcome:
                    welcomePage
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing),
                            removal: .move(edge: .leading)
                        ))
                case .features:
                    featuresPage
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing),
                            removal: .move(edge: .leading)
                        ))
                case .permissions:
                    permissionsPage
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing),
                            removal: .move(edge: .leading)
                        ))
                case .apiKey:
                    apiKeyPage
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing),
                            removal: .move(edge: .leading)
                        ))
                case .completion:
                    completionPage
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing),
                            removal: .move(edge: .leading)
                        ))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: currentPage)

            Spacer()

            // Navigation
            VStack(spacing: 16) {
                // Page dots
                HStack(spacing: 8) {
                    ForEach(OnboardingPage.allCases, id: \.rawValue) { page in
                        Circle()
                            .fill(page == currentPage ? Color.blue : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }

                // Buttons
                HStack {
                    if currentPage.rawValue > 0 && currentPage != .completion {
                        Button("Back") {
                            goBack()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    navigationButton
                }
                .padding(.horizontal, 30)
            }
            .padding(.bottom, 24)
        }
        .frame(width: 560, height: 620)
        .onAppear {
            permissionManager.checkAll()
            if let key = keychainManager?.getAPIKey(), !key.isEmpty {
                apiKey = key
                didSaveKey = true
            }
        }
    }

    // MARK: - Navigation Button

    @ViewBuilder
    private var navigationButton: some View {
        switch currentPage {
        case .welcome, .features:
            Button("Continue") {
                goForward()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

        case .permissions:
            Button("Continue") {
                goForward()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!permissionManager.allPermissionsGranted)

        case .apiKey:
            EmptyView()

        case .completion:
            Button("Get Started") {
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Page Navigation

    private func goForward() {
        guard let nextPage = OnboardingPage(rawValue: currentPage.rawValue + 1) else { return }
        withAnimation {
            currentPage = nextPage
        }
    }

    private func goBack() {
        guard let prevPage = OnboardingPage(rawValue: currentPage.rawValue - 1) else { return }
        withAnimation {
            currentPage = prevPage
        }
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        VStack(spacing: 16) {
            Spacer()
                .frame(height: 60)

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue, .blue.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 88, height: 88)

                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.white)
            }

            Text("Welcome to Dictify")
                .font(.system(size: 26, weight: .bold))

            Text("Intelligent Voice-to-Text for macOS")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("Press a key, speak naturally, and your words\nappear wherever you type.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Page 2: Features

    private var featuresPage: some View {
        VStack(spacing: 24) {
            Spacer()
                .frame(height: 30)

            Text("How It Works")
                .font(.system(size: 22, weight: .bold))

            VStack(spacing: 16) {
                FeatureCard(
                    icon: "hand.tap.fill",
                    color: .blue,
                    title: "Hold to Dictate",
                    description: "Press and hold your activation key, speak naturally, then release to transcribe"
                )

                FeatureCard(
                    icon: "sparkles",
                    color: .purple,
                    title: "AI Refinement",
                    description: "Automatically removes filler words, fixes grammar, and adds proper punctuation"
                )

                FeatureCard(
                    icon: "macwindow.on.rectangle",
                    color: .green,
                    title: "Works Everywhere",
                    description: "Text is inserted directly into any app — browsers, editors, messaging apps"
                )
            }
            .padding(.horizontal, 30)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Page 3: Permissions

    private var permissionsPage: some View {
        VStack(spacing: 16) {
            Spacer()
                .frame(height: 30)

            Image(systemName: "shield.checkered")
                .font(.system(size: 36))
                .foregroundStyle(.blue)

            Text("Permissions Required")
                .font(.system(size: 22, weight: .bold))

            Text("Dictify needs two permissions to work")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 16) {
                PermissionStep(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "Required to capture your voice for transcription",
                    isGranted: permissionManager.microphoneGranted,
                    isCurrent: !permissionManager.microphoneGranted,
                    action: {
                        Task {
                            let granted = await permissionManager.requestMicrophonePermission()
                            if granted {
                                permissionManager.checkAll()
                            }
                        }
                    }
                )

                PermissionStep(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: isRequestingAccessibilityPermission
                        ? "Enable Dictify in System Settings, then return here"
                        : "Find Dictify in the list and enable it, then return here",
                    isGranted: permissionManager.accessibilityGranted,
                    isCurrent: permissionManager.microphoneGranted && !permissionManager.accessibilityGranted,
                    isActionInProgress: isRequestingAccessibilityPermission,
                    buttonLabel: isRequestingAccessibilityPermission ? "Check Again" : "Open Settings",
                    action: {
                        permissionManager.checkAll()
                        if permissionManager.accessibilityGranted {
                            isRequestingAccessibilityPermission = false
                            return
                        }

                        onAccessibilityPermissionRequest()
                        permissionManager.openAccessibilitySettings()
                        isRequestingAccessibilityPermission = true
                        permissionManager.startPollingAccessibility { _ in
                            isRequestingAccessibilityPermission = false
                            permissionManager.checkAll()
                        }
                    }
                )
            }
            .padding(.horizontal, 30)

            if permissionManager.allPermissionsGranted {
                Label("All permissions granted", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                    .padding(.top, 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            permissionManager.checkAll()
            isRequestingAccessibilityPermission = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionManager.checkAll()
            if permissionManager.accessibilityGranted {
                isRequestingAccessibilityPermission = false
                permissionManager.stopPollingAccessibility()
            }
        }
    }

    // MARK: - Page 4: API Key

    private var apiKeyPage: some View {
        VStack(spacing: 16) {
            Spacer()
                .frame(height: 30)

            Image(systemName: "key.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            Text("Groq API Key")
                .font(.system(size: 22, weight: .bold))

            Text("Dictify uses Groq's API for transcription and AI refinement")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            VStack(spacing: 12) {
                HStack {
                    if showKey {
                        TextField("Enter your Groq API key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Enter your Groq API key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button(action: { showKey.toggle() }) {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                Text("Get your free API key from [console.groq.com](https://console.groq.com)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                    Text("Your API key is stored securely in Apple Keychain and never leaves your Mac.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)

                if didSaveKey {
                    Label("API key saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 40)

            Spacer()
                .frame(height: 16)

            VStack(spacing: 10) {
                Button(action: {
                    saveError = nil
                    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

                    guard !trimmedKey.isEmpty else {
                        goForward()
                        return
                    }

                    guard let km = keychainManager else {
                        didSaveKey = false
                        saveError = "Unable to access Keychain. Please try again."
                        return
                    }

                    didSaveKey = km.saveAPIKey(trimmedKey)
                    if didSaveKey {
                        apiKey = trimmedKey
                        onAPIKeySaved()
                        goForward()
                    } else {
                        saveError = "Could not save your API key to Keychain. Please try again."
                    }
                }) {
                    Text(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Skip for Now" : "Save & Continue")
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let saveError {
                    Text(saveError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                } else if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !didSaveKey {
                    Text("Key will be saved when you continue")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Page 5: Completion

    private var completionPage: some View {
        VStack(spacing: 16) {
            Spacer()
                .frame(height: 50)

            ZStack {
                Circle()
                    .fill(.green.opacity(0.15))
                    .frame(width: 80, height: 80)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
            }

            Text("You're All Set!")
                .font(.system(size: 26, weight: .bold))

            Text("Dictify is ready to use")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                UsageTip(
                    icon: "hand.tap.fill",
                    text: "Hold **fn** to start recording"
                )
                UsageTip(
                    icon: "waveform",
                    text: "Speak naturally while holding the key"
                )
                UsageTip(
                    icon: "text.cursor",
                    text: "Release to transcribe and insert text"
                )
                UsageTip(
                    icon: "menubar.arrow.up.rectangle",
                    text: "Click the menu bar icon to see history and stats"
                )
            }
            .padding(.horizontal, 50)
            .padding(.top, 12)

            if keychainManager?.hasAPIKey != true {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Configure your Groq API key from the menu bar to start transcribing.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal, 40)
                .padding(.top, 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Supporting Views

private struct FeatureCard: View {
    let icon: String
    let color: Color
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.12))
                    .frame(width: 44, height: 44)

                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(14)
        .background(.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct PermissionStep: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let isCurrent: Bool
    var isActionInProgress = false
    var buttonLabel: String = "Enable"
    let action: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(isGranted ? .green.opacity(0.15) : (isCurrent ? .blue.opacity(0.15) : .gray.opacity(0.1)))
                    .frame(width: 44, height: 44)

                Image(systemName: isGranted ? "checkmark.circle.fill" : icon)
                    .font(.title3)
                    .foregroundStyle(isGranted ? .green : (isCurrent ? .blue : .secondary))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isGranted {
                Text("Granted")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if isCurrent {
                HStack(spacing: 8) {
                    if isActionInProgress {
                        ProgressView()
                            .scaleEffect(0.6)
                    }

                    Button(buttonLabel) { action() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .padding(16)
        .background(.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct UsageTip: View {
    let icon: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.blue)
                .frame(width: 24)

            Text(text)
                .font(.subheadline)
        }
    }
}
