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
/// Contract: only pause when something is actually playing, and only resume what
/// *we* paused — so dictating with nothing playing never starts media.
@MainActor
final class MediaPlaybackController {
    #if arch(arm64)
    private let controller = MediaController()
    #endif

    init() {}

    #if arch(arm64)
    /// Pauses system media if it is currently playing.
    /// - Returns: `true` only if we issued a pause command.
    func pauseIfPlaying() async -> Bool {
        await withCheckedContinuation { continuation in
            // `MediaController` can fire its callback more than once; a one-shot
            // gate prevents a double `resume` of the continuation (a crash).
            let lock = NSLock()
            var resumed = false
            func finish(_ value: Bool) {
                lock.lock()
                let first = !resumed
                resumed = true
                lock.unlock()
                guard first else { return }
                continuation.resume(returning: value)
            }

            // `getTrackInfo` drives a helper subprocess; if it stalls and never
            // calls back, the continuation would hang the dictation forever.
            // Bail out as "nothing playing" after a short timeout so recording
            // is never blocked on the media helper.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                finish(false)
            }

            controller.getTrackInfo { [weak self] trackInfo in
                guard let self, let trackInfo else { finish(false); return }
                let isPlaying = trackInfo.payload.isPlaying ?? ((trackInfo.payload.playbackRate ?? 0) > 0)
                guard isPlaying else { finish(false); return }
                self.controller.pause()
                Log.media.notice("Paused system media for dictation")
                finish(true)
            }
        }
    }

    /// Resumes media only if `wePaused` is `true` (i.e. `pauseIfPlaying` paused it).
    func resumeIfWePaused(_ wePaused: Bool) {
        guard wePaused else { return }
        controller.play()
        Log.media.notice("Resumed system media after dictation")
    }
    #else
    func pauseIfPlaying() async -> Bool { false }
    func resumeIfWePaused(_ wePaused: Bool) {}
    #endif
}
