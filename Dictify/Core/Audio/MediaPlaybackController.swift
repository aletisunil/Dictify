import Foundation
#if arch(arm64)
import MediaRemoteAdapter
#endif

/// Pauses and resumes system media playback around a dictation.
///
/// macOS 15.4+ made the private MediaRemote framework non-functional when loaded
/// directly in-process, so we go through `MediaRemoteAdapter`, which drives the
/// framework via the entitled system Perl binary in a helper subprocess. The
/// adapter is arm64-only; Intel Macs get an inert stub.
///
/// While the feature is enabled the helper runs in *listener* mode, so it keeps
/// a live now-playing state here that `pauseForDictation()` reads with no I/O,
/// and pause/play travel down the helper's stdin pipe. The previous design
/// spawned a fresh `perl` process per dictation and waited up to a second for a
/// three-hop XPC round trip to answer "is anything playing?" - when the answer
/// ran long (an App-Napped source app, a throttled browser tab, or simply the
/// load of starting capture) it was read as "nothing is playing" and the pause
/// was silently skipped.
///
/// Contract: only pause when something is actually playing, and only resume what
/// *we* paused - so dictating with nothing playing never starts media.
@MainActor
final class MediaPlaybackController {
    private let settings: DictifySettings

    #if arch(arm64)
    private let controller = MediaController()

    /// Latest playback state reported by the listener, and whether the listener
    /// has reported at all. Without a report we have no opinion, and must ask
    /// the one-shot helper rather than assume nothing is playing.
    private var isPlaying = false
    private var hasLiveState = false
    private var isListening = false

    /// True between `pauseForDictation()` and `resumeAfterDictation()`, with a
    /// token identifying the current dictation. A late answer from a one-shot
    /// probe belongs to the dictation that asked for it; if that dictation is
    /// over, the answer is dropped rather than pausing media out of nowhere.
    private var dictationActive = false
    private var dictationToken = 0

    /// Tracked here (rather than on the pipeline actor) so a synchronous caller
    /// - app termination - can resume without hopping onto that actor.
    private var pausedByUs = false

    /// Consecutive listener deaths, used to stop restarting a helper that
    /// cannot stay up. Reset by any successful report, and by switching the
    /// feature off and on again.
    private var listenerRestarts = 0
    private var listenerGaveUp = false
    private static let maxListenerRestarts = 5

    private var defaultsObserver: NSObjectProtocol?
    #endif

    init(settings: DictifySettings) {
        self.settings = settings
    }

    #if arch(arm64)
    /// Brings the helper up (if the feature is on) and keeps it in step with the
    /// setting. Called once at launch: by the time the first hotkey lands, the
    /// listener has already reported, so the pause costs a pipe write.
    func start() {
        syncListener()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncListener()
            }
        }
    }

    func invalidate() {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        stopListening()
    }

    /// Pauses system media for a dictation that is starting, if something is
    /// playing. Returns immediately - never blocks the hotkey path.
    func pauseForDictation() {
        dictationToken &+= 1
        dictationActive = true
        let token = dictationToken

        guard settings.pauseMediaDuringDictation else { return }
        // Don't trust a report from a helper that is no longer there, and bring
        // the listener up if the setting was switched on since the last defaults
        // change we saw.
        reconcileListener()
        syncListener()

        if hasLiveState {
            if isPlaying {
                sendPause(token: token)
            }
            return
        }

        // No live state yet - the app launched moments ago, or the helper is
        // restarting. Ask the one-shot helper, off the critical path, and apply
        // the answer late if this dictation is still running.
        probeAndPauseIfPlaying(token: token)
    }

    /// Resumes system media iff we paused it for this dictation. Idempotent, and
    /// safe to call for a dictation that never paused anything.
    func resumeAfterDictation() {
        dictationToken &+= 1
        dictationActive = false
        guard pausedByUs else { return }
        pausedByUs = false
        controller.play()
        // The listener needs a beat to report the resumed playback. Until it
        // does, assume media is back: a second dictation started inside that
        // window must not read the stale "nothing is playing" and skip its
        // pause. Any real report supersedes this.
        isPlaying = true
        Log.media.notice("Resumed system media after dictation")
    }

    /// Best-effort resume at app termination, so quitting mid-dictation doesn't
    /// leave system media paused forever. Everything here is synchronous: the
    /// app gets no further turn of the run loop, so anything queued is lost.
    func resumeOnTerminate() {
        dictationActive = false
        guard pausedByUs else { return }
        pausedByUs = false
        // Drop the listener *first*. With no helper attached, the play command
        // is carried by a short-lived `perl` process that `playBlocking` waits
        // on, so it cannot be cut short. Writing to the attached helper instead
        // logs a resume that never happens: the helper is torn down a moment
        // later, before it can forward the command to MediaRemote.
        stopListening()
        controller.playBlocking()
        Log.media.notice("Resumed system media on app termination")
    }

    // MARK: - Commands

    private func sendPause(token: Int) {
        guard !pausedByUs else { return }
        pausedByUs = true
        controller.pause()
        Log.media.notice("Paused system media for dictation")
        verifyPause(token: token)
    }

    /// The pause command is fire-and-forget: the helper reports no result. The
    /// listener does, though - a pause that landed shows up as `isPlaying`
    /// going false. If it doesn't, say so, so a silent failure leaves a trace
    /// instead of a log line claiming success.
    private func verifyPause(token: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard token == self.dictationToken, self.pausedByUs else { return }
                guard self.hasLiveState, self.isPlaying else { return }
                Log.media.error("Pause command did not take effect - media is still playing")
            }
        }
    }

    private func probeAndPauseIfPlaying(token: Int) {
        controller.getTrackInfo { [weak self] trackInfo in
            guard let self else { return }
            guard token == self.dictationToken, self.dictationActive else { return }
            guard let trackInfo else {
                Log.media.notice("Now-playing probe returned no state; leaving media alone")
                return
            }
            guard Self.isPlaying(trackInfo) else { return }
            self.sendPause(token: token)
        }
    }

    // MARK: - Listener

    private func syncListener() {
        if settings.pauseMediaDuringDictation {
            startListening()
        } else {
            stopListening()
        }
    }

    private func startListening() {
        // `listenerGaveUp` outranks the setting: without it the `syncListener()`
        // on the next dictation would restart the helper the cap just gave up on.
        guard !isListening, !listenerGaveUp else { return }
        isListening = true

        controller.onTrackInfoReceived = { [weak self] trackInfo in
            guard let self else { return }
            self.listenerRestarts = 0
            self.hasLiveState = true
            // A `nil` payload is the helper's way of saying nothing is playing,
            // which is a real answer - unlike a probe that never came back.
            self.isPlaying = trackInfo.map(Self.isPlaying) ?? false
        }

        controller.onListenerTerminated = { [weak self] in
            guard let self, self.isListening else { return }
            self.handleListenerDeath(reason: "terminated")
        }

        controller.startListening()
    }

    /// Catches a listener that went away without saying so. `onListenerTerminated`
    /// is suppressed for a helper that died having only ever reported "nothing
    /// playing", and never fires when a respawn fails to launch - so without this
    /// check `hasLiveState` would keep answering from a process that no longer
    /// exists, and every remaining dictation in the session would skip its pause.
    /// That is the failure this controller exists to prevent, so it is worth one
    /// cheap liveness check per dictation.
    private func reconcileListener() {
        guard isListening, !controller.isListenerActive else { return }
        handleListenerDeath(reason: "gone without notice")
    }

    /// The helper is dead: its last report is no longer trustworthy, so drop the
    /// cached state (dictations fall back to one-shot probes) and try to bring a
    /// listener back, up to a cap so a helper that cannot stay up isn't respawned
    /// forever.
    private func handleListenerDeath(reason: String) {
        isListening = false
        hasLiveState = false
        isPlaying = false
        listenerRestarts += 1
        guard listenerRestarts <= Self.maxListenerRestarts else {
            listenerGaveUp = true
            Log.media.error("Media helper died repeatedly; falling back to per-dictation probes")
            return
        }
        Log.media.notice("Media helper \(reason, privacy: .public); restarting")
        startListening()
    }

    private func stopListening() {
        // Turning the feature off and on again is the user's way of asking for a
        // fresh start, so it clears a helper we had given up on.
        listenerRestarts = 0
        listenerGaveUp = false
        guard isListening else { return }
        isListening = false
        controller.onTrackInfoReceived = nil
        controller.onListenerTerminated = nil
        controller.stopListening()
        hasLiveState = false
        isPlaying = false
    }

    /// `isPlaying` is the authoritative field; a non-zero playback rate is the
    /// fallback for sources that report the rate but not the flag.
    private static func isPlaying(_ trackInfo: TrackInfo) -> Bool {
        trackInfo.payload.isPlaying ?? ((trackInfo.payload.playbackRate ?? 0) > 0)
    }
    #else
    func start() {}
    func invalidate() {}
    func pauseForDictation() {}
    func resumeAfterDictation() {}
    func resumeOnTerminate() {}
    #endif
}
