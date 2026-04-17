import Foundation
import SwiftUI
import Combine

enum PipelineState: Equatable {
    case idle
    case recording
    case transcribing
    case refining
    case inserting
    case error(String)

    var isProcessing: Bool {
        switch self {
        case .transcribing, .refining, .inserting: return true
        default: return false
        }
    }

    var statusLabel: String {
        switch self {
        case .idle: return ""
        case .recording: return "Listening..."
        case .transcribing: return "Transcribing..."
        case .refining: return "Refining..."
        case .inserting: return "Inserting..."
        case .error(let msg): return msg
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var pipelineState: PipelineState = .idle
    @Published var audioLevels: [Float] = Array(repeating: 0, count: 15)
    @Published var recordingElapsed: TimeInterval = 0
    @Published private(set) var hasAPIKeyConfigured = false

    var dictionaryStore: DictionaryStore? {
        didSet {
            dictionaryStoreCancellable = dictionaryStore?.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
    private var dictionaryStoreCancellable: AnyCancellable?

    var snippetStore: SnippetStore? {
        didSet {
            snippetStoreCancellable = snippetStore?.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
    private var snippetStoreCancellable: AnyCancellable?

    var statsStore: StatsStore? {
        didSet {
            statsStoreCancellable = statsStore?.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
    private var statsStoreCancellable: AnyCancellable?

    var historyStore: HistoryStore? {
        didSet {
            historyStoreCancellable = historyStore?.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
    private var historyStoreCancellable: AnyCancellable?

    var keychainManager: KeychainManager? {
        didSet {
            hasAPIKeyConfigured = keychainManager?.hasStoredAPIKeyHint == true
        }
    }

    let settings = DictifySettings()

    func refreshAPIKeyStatus() {
        hasAPIKeyConfigured = keychainManager?.refreshStoredAPIKeyHint() == true
    }

    func refreshAPIKeyStatusFromStoredHint() {
        hasAPIKeyConfigured = keychainManager?.hasStoredAPIKeyHint == true
    }

    func playSound(_ name: String) {
        guard settings.soundEffectsEnabled else { return }
        NSSound(named: name)?.play()
    }
}
