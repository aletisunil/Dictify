import SwiftUI
import AVFoundation
import AppKit

// MARK: - Onboarding Pages

private enum OnboardingPage: Int, CaseIterable {
    case welcome = 0
    case features = 1
    case permissions = 2
    case apiKey = 3
    case personalize = 4
    case completion = 5
}

// MARK: - Main Onboarding View

struct PermissionOnboardingView: View {
    @ObservedObject var permissionManager: PermissionManager
    var keychainManager: KeychainManager?
    let onAPIKeySaved: () -> Void
    let onComplete: () -> Void

    @State private var currentPage: OnboardingPage = .welcome
    @State private var isRequestingAccessibilityPermission = false
    @State private var isRequestingMicrophonePermission = false

    // API Key state
    @State private var apiKey = ""
    @State private var showKey = false
    @State private var didSaveKey = false
    @State private var saveError: String?
    @State private var validationError: String?
    @State private var isTestingKey = false
    @State private var testKeyResult: OnboardingTestResult?

    enum OnboardingTestResult: Equatable {
        case success
        case failure(String)
    }

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
                case .personalize:
                    personalizePage
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
        .frame(width: 560, height: 680)
        .onAppear {
            permissionManager.checkAll()
            didSaveKey = keychainManager?.hasStoredAPIKeyHint == true
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

        case .personalize:
            Button("Continue") {
                goForward()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

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
        guard var nextPage = OnboardingPage(rawValue: currentPage.rawValue + 1) else { return }
        // If the user is replaying onboarding and already has a Groq key saved,
        // there's nothing to do on the API-key page — skip straight past it.
        if nextPage == .apiKey, keychainManager?.hasStoredAPIKeyHint == true {
            if let afterApiKey = OnboardingPage(rawValue: OnboardingPage.apiKey.rawValue + 1) {
                nextPage = afterApiKey
            }
        }
        withAnimation {
            currentPage = nextPage
        }
    }

    private func goBack() {
        guard var prevPage = OnboardingPage(rawValue: currentPage.rawValue - 1) else { return }
        if prevPage == .apiKey, keychainManager?.hasStoredAPIKeyHint == true {
            if let beforeApiKey = OnboardingPage(rawValue: OnboardingPage.apiKey.rawValue - 1) {
                prevPage = beforeApiKey
            }
        }
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
        .onAppear {
            didSaveKey = keychainManager?.hasStoredAPIKeyHint == true
        }
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

                FeatureCard(
                    icon: "wand.and.stars",
                    color: .pink,
                    title: "Your Vocabulary",
                    description: "Teach Dictify rare words and turn short cues into longer text — set up after onboarding"
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
                    description: permissionManager.microphoneDenied
                        ? (isRequestingMicrophonePermission
                            ? "Enable Dictify in System Settings, then return here"
                            : "Microphone access was previously denied — enable it in System Settings")
                        : "Required to capture your voice for transcription",
                    isGranted: permissionManager.microphoneGranted,
                    isCurrent: !permissionManager.microphoneGranted,
                    isActionInProgress: isRequestingMicrophonePermission,
                    buttonLabel: permissionManager.microphoneDenied
                        ? (isRequestingMicrophonePermission ? "Check Again" : "Open Settings")
                        : "Enable",
                    action: {
                        // When the user has previously denied microphone access
                        // (common after reinstall — TCC retains the decision),
                        // requestAccess returns false instantly without any
                        // prompt. Send them to System Settings instead.
                        if permissionManager.microphoneDenied {
                            permissionManager.checkMicrophonePermission()
                            if permissionManager.microphoneGranted {
                                isRequestingMicrophonePermission = false
                                return
                            }
                            permissionManager.openMicrophoneSettings()
                            isRequestingMicrophonePermission = true
                            permissionManager.startPollingMicrophone { _ in
                                isRequestingMicrophonePermission = false
                                permissionManager.checkAll()
                            }
                            return
                        }
                        Task {
                            let granted = await permissionManager.requestMicrophonePermission()
                            if granted {
                                permissionManager.checkAll()
                            } else {
                                // First request returned false — status is now
                                // .denied. Refresh so the next tap routes to
                                // System Settings.
                                permissionManager.checkMicrophonePermission()
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
            isRequestingMicrophonePermission = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionManager.checkAll()
            if permissionManager.accessibilityGranted {
                isRequestingAccessibilityPermission = false
                permissionManager.stopPollingAccessibility()
            }
            if permissionManager.microphoneGranted {
                isRequestingMicrophonePermission = false
                permissionManager.stopPollingMicrophone()
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
                HStack(spacing: 10) {
                    Button(action: {
                        saveAndContinue()
                    }) {
                        Text(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (didSaveKey ? "Continue" : "Skip for Now") : "Save & Continue")
                            .frame(width: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(action: { testKey() }) {
                        if isTestingKey {
                            ProgressView().scaleEffect(0.6)
                                .frame(width: 80)
                        } else {
                            Text("Test Key").frame(width: 80)
                        }
                    }
                    .controlSize(.large)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingKey)
                }

                if let validationError {
                    Text(validationError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                } else if let saveError {
                    Text(saveError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                } else if let testKeyResult {
                    switch testKeyResult {
                    case .success:
                        Label("API key works", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    case .failure(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
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

    // MARK: - API Key helpers

    private func validate(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed != key {
            return "Key has leading/trailing whitespace — paste without it."
        }
        if !trimmed.hasPrefix("gsk_") {
            return "Groq keys start with \"gsk_\". Double-check what you pasted."
        }
        if trimmed.count < 20 {
            return "That key looks too short. Copy the full value from console.groq.com."
        }
        return nil
    }

    private func saveAndContinue() {
        saveError = nil
        validationError = nil
        testKeyResult = nil

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            goForward()
            return
        }

        if let issue = validate(apiKey) {
            validationError = issue
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
    }

    private func testKey() {
        validationError = nil
        saveError = nil
        testKeyResult = nil

        if let issue = validate(apiKey) {
            validationError = issue
            return
        }

        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let km = keychainManager else { return }

        // Persist the key before testing so GroqClient can read it back.
        _ = km.saveAPIKey(trimmed)
        apiKey = trimmed

        isTestingKey = true
        Task {
            let result = await Self.testKeyAgainstGroq(keychainManager: km)
            await MainActor.run {
                self.testKeyResult = result
                self.isTestingKey = false
                if case .success = result {
                    self.didSaveKey = true
                    self.onAPIKeySaved()
                }
            }
        }
    }

    private static func testKeyAgainstGroq(keychainManager: KeychainManager) async -> OnboardingTestResult {
        let client = GroqClient(keychainManager: keychainManager)
        guard let url = URL(string: Constants.API.modelsEndpoint) else {
            return .failure("Internal error")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            _ = try await client.performRequest(request)
            return .success
        } catch APIError.unauthorized {
            return .failure("Key rejected by Groq (401). Check it at console.groq.com.")
        } catch APIError.networkError {
            return .failure("No internet connection.")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Page 5: Personalize (Dictionary + Snippets explainer)

    private var personalizePage: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 24)

            Image(systemName: "wand.and.stars")
                .font(.system(size: 34))
                .foregroundStyle(.purple)

            Text("Make Dictify Yours")
                .font(.system(size: 22, weight: .bold))

            Text("Two optional features that make transcription feel tailor-made.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            VStack(spacing: 12) {
                PersonalizationCard(
                    icon: "character.book.closed.fill",
                    color: .blue,
                    title: "Dictionary",
                    tagline: "Teach Dictify rare words so it hears them correctly.",
                    youSay: "let's use kubernetes",
                    dictifyWrites: "Kubernetes",
                    footnote: "Add names, brands, or jargon anytime from Settings → Dictionary."
                )

                PersonalizationCard(
                    icon: "text.badge.plus",
                    color: .pink,
                    title: "Snippets",
                    tagline: "Turn short spoken cues into longer text.",
                    youSay: "signoff",
                    dictifyWrites: "Thanks,\nSunil",
                    footnote: "Supports {{date}}, {{time}}, {{clipboard}}. Manage in Settings → Snippets."
                )
            }
            .padding(.horizontal, 30)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Page 6: Completion

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
                    icon: "character.book.closed.fill",
                    text: "Add **Dictionary** terms and **Snippets** from Settings"
                )
            }
            .padding(.horizontal, 50)
            .padding(.top, 12)

            if keychainManager?.hasStoredAPIKeyHint != true {
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

private struct PersonalizationCard: View {
    let icon: String
    let color: Color
    let title: String
    let tagline: String
    let youSay: String
    let dictifyWrites: String
    let footnote: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color.opacity(0.14))
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.headline)
                        .foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.headline)
                    Text(tagline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("You say:")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\u{201C}\(youSay)\u{201D}")
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(color)
                    Text("Dictify writes:")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(dictifyWrites)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.06))
            )

            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
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
