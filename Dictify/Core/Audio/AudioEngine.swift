@preconcurrency import AVFoundation
import Accelerate
import AppKit
import CoreAudio
import os

/// A selectable audio input (microphone) device.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Thin Core Audio wrapper for enumerating input devices and resolving the
/// user's stored device UID to a live `AudioDeviceID`. UIDs are stable across
/// reconnects/reboots; raw `AudioDeviceID`s are not, so we persist the UID.
enum AudioDeviceManager {
    /// All currently-connected devices that expose at least one input channel.
    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard inputChannelCount(of: id) > 0,
                  let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, selector: kAudioObjectPropertyName)
            else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    /// Resolves a stored UID to the current device ID, or nil if it's gone.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return inputDevices().first { $0.uid == uid }?.id
    }

    /// Device macOS currently uses as the default input — i.e. what
    /// "System Default" actually routes to right now.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    /// Name of the current default input device (e.g. "MacBook Pro Microphone").
    static func defaultInputDeviceName() -> String? {
        guard let deviceID = defaultInputDeviceID() else { return nil }
        return stringProperty(deviceID, selector: kAudioObjectPropertyName)
    }

    // MARK: - Core Audio plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func inputChannelCount(of device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return 0 }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return 0
        }
        let abl = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self)
        )
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString? = nil
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}

/// Reason why an in-flight recording was forcibly terminated.
///
/// The pipeline surfaces these to the user as recoverable errors — none are crashes.
enum AudioEngineInterruption: Sendable, Equatable {
    case deviceChanged
    case systemSleep
    case bufferOverflow
    case conversionFailed(String)

    var userMessage: String {
        switch self {
        case .deviceChanged: return "Audio device changed. Please try again."
        case .systemSleep: return "Recording interrupted by sleep."
        case .bufferOverflow: return "Recording too long — please try again."
        case .conversionFailed: return "Audio conversion failed. Please try again."
        }
    }
}

final class AudioEngine: @unchecked Sendable {
    // Serial queue guarding *all* mutable state below. Never block the audio
    // thread on it for long — only short `sync` appends + state reads.
    private let stateQueue = DispatchQueue(label: "com.dictify.audioengine.state")

    // Recreated during start retries: once an input route goes bad, the engine's
    // inputNode can hold a stale hardware format that `reset()` does not flush,
    // and every subsequent start fails with -10868 until the instance is replaced.
    private var engine = AVAudioEngine()

    // --- state guarded by stateQueue ---
    private var audioBuffer = Data()
    private var recordingStartTime: Date?
    private var tapInstalled = false
    private var currentConverter: AVAudioConverter?
    private var currentTargetFormat: AVAudioFormat?
    /// The live input format the cached `currentConverter` was built for. Bluetooth
    /// devices (e.g. AirPods) can change rate after capture starts, so we rebuild
    /// the converter when the tap delivers a buffer in a different format.
    private var currentInputFormat: AVAudioFormat?
    private var overflowed = false
    // ------------------------------------

    private var configObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var interruptionHandler: (@Sendable (AudioEngineInterruption) -> Void)?

    // Retained so the configuration-change recovery path can reinstall the tap
    // and re-target the selected device without the caller re-invoking startCapture.
    // All three are read/written under stateQueue.
    private var levelCallback: (@MainActor @Sendable ([Float]) -> Void)?
    private var preferredDeviceUID: String = ""
    /// True while a config-change recovery is in flight, so the burst of
    /// notifications a single route switch emits doesn't stack restarts.
    private var isRecovering = false
    /// Bumped on every start/stop/teardown. A recovery captures the value at
    /// entry and bails if it changed (capture ended underneath it).
    private var captureGeneration = 0

    private let targetSampleRate: Double = Constants.Audio.sampleRate
    private let targetChannels: AVAudioChannelCount = AVAudioChannelCount(Constants.Audio.channels)

    /// Belt-and-braces cap on captured PCM. The primary safeguard is the
    /// `maxRecordingDuration` timer in `TranscriptionPipeline`; this protects
    /// against a runaway tap callback if the timer is delayed or leaks.
    private static let maxBufferBytes: Int = 50 * 1024 * 1024

    var isRecording: Bool {
        let tapped = stateQueue.sync { tapInstalled }
        return tapped && engine.isRunning
    }

    var recordingDuration: TimeInterval {
        stateQueue.sync {
            guard let start = recordingStartTime else { return 0 }
            return Date().timeIntervalSince(start)
        }
    }

    /// Front-load the AUHAL graph build so the first real capture doesn't pay
    /// the CoreAudio cold start. Touching `inputNode` instantiates the input
    /// unit and binds the default device; `prepare()` preallocates render
    /// resources. No tap is installed and the engine is not started, so no
    /// audio I/O runs and the system mic-in-use indicator stays off.
    /// Call only when microphone permission is already granted.
    func prewarm() {
        let busy = stateQueue.sync { tapInstalled }
        guard busy == false else { return }
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        engine.prepare()
        Log.audio.notice("Engine prewarmed (input: \(inputFormat.sampleRate, privacy: .public) Hz, \(inputFormat.channelCount, privacy: .public) ch)")
    }

    /// Begin capture. `onInterruption` is invoked (on main) when the engine is
    /// torn down due to a device/route change, system sleep, buffer overflow,
    /// or converter error. Callers should treat it as a terminal error signal
    /// for the current recording.
    func startCapture(
        preferredDeviceUID: String = "",
        levelCallback: @escaping @MainActor @Sendable ([Float]) -> Void,
        onInterruption: @escaping @Sendable (AudioEngineInterruption) -> Void
    ) async throws {
        let already = stateQueue.sync { tapInstalled }
        guard !already else { throw AudioEngineError.alreadyRecording }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else {
            throw AudioEngineError.formatCreationFailed
        }

        stateQueue.sync {
            audioBuffer = Data()
            audioBuffer.reserveCapacity(
                Int(targetSampleRate * Double(Constants.Audio.maxRecordingDuration)) * MemoryLayout<Float>.size
            )
            // Set on the first delivered tap buffer (`handleTap`), not here:
            // engine start can spend 0.2–1.5s settling a Bluetooth route, and
            // counting that as recording time inflates duration, deflates WPM,
            // and lets a near-empty capture pass the min-duration gate.
            recordingStartTime = nil
            currentConverter = nil
            currentInputFormat = nil
            currentTargetFormat = targetFormat
            overflowed = false
            self.levelCallback = levelCallback
            self.preferredDeviceUID = preferredDeviceUID
            isRecovering = false
            captureGeneration += 1
        }
        interruptionHandler = onInterruption

        // Installing the tap and starting the engine can fail on a fresh Bluetooth
        // route: engaging the mic flips AirPods from A2DP (48 kHz, output-only) into
        // HFP (24 kHz, bidirectional), and that switch happens *during* the first
        // `engine.start()`. The tap was installed against the pre-switch 48 kHz node
        // format, so graph init aborts with a format mismatch (-10868) before any
        // buffer is delivered. The first attempt provokes the switch; retrying once
        // the route settles picks up the node's new format and succeeds.
        do {
            try await startEngineWithRetry(preferredDeviceUID: preferredDeviceUID, levelCallback: levelCallback)
        } catch {
            // Roll back partial state; do not fire interruption handler for a
            // start failure — the throw is the signal.
            engine.inputNode.removeTap(onBus: 0)
            stateQueue.sync {
                tapInstalled = false
                recordingStartTime = nil
                currentConverter = nil
                currentInputFormat = nil
                currentTargetFormat = nil
                audioBuffer = Data()
            }
            interruptionHandler = nil
            throw error
        }

        // Install observers only after a clean start: the A2DP→HFP switch we provoke
        // above fires an AVAudioEngineConfigurationChange, and reacting to it mid-retry
        // would tear down capture just as it's coming up.
        installObservers()
    }

    /// Installs the input tap and starts the engine, retrying when a Bluetooth
    /// route switch (notably AirPods dropping into 24 kHz HFP mode as the mic
    /// engages) makes the node's format disagree with the live hardware format and
    /// graph initialization fails with -10868. Each failed attempt provokes — and
    /// then lets settle — the route change, so a later attempt sees a stable format.
    ///
    /// If retries on the existing engine keep failing, the engine instance itself
    /// is replaced: a bad route change can leave the inputNode with a stale
    /// hardware format that `reset()` never flushes, making -10868 permanent for
    /// the life of the instance (and otherwise curable only by relaunching the app).
    private func startEngineWithRetry(
        preferredDeviceUID: String,
        levelCallback: @escaping @MainActor @Sendable ([Float]) -> Void,
        maxAttempts: Int = 4
    ) async throws {
        let bufferSize: AVAudioFrameCount = 4096
        var lastError: Error?
        // Snapshot at entry: a stopCapture/tearDown during an await bumps this,
        // and we must not bring the engine back up underneath it.
        let generation = stateQueue.sync { captureGeneration }
        // Resolve the selected mic once — `deviceID(forUID:)` enumerates every
        // CoreAudio device. Re-resolved only when the engine is replaced, since
        // a device can (dis)appear across the longer backoffs.
        //
        // Fall back to the *explicit* system-default device when the UID is
        // empty or no longer resolves (mic unplugged). `stopCapture` parks the
        // AUHAL on kAudioObjectUnknown to release Bluetooth routes; without an
        // explicit rebind here the reused engine starts with no device and a
        // stale client format, and graph init fails -10868 on every attempt
        // until the instance is replaced — a guaranteed ~750ms of lost speech
        // per dictation. Binding the default (plus the format reconcile in
        // `applyPreferredInputDevice`) restores the known-good start path.
        var preferredDevice = Self.resolveInputDevice(preferredUID: preferredDeviceUID)

        for attempt in 1...maxAttempts {
            guard stateQueue.sync(execute: { captureGeneration }) == generation else {
                throw AudioEngineError.startAborted
            }
            // Attempts 1–2 retry the existing engine (covers the normal HFP
            // settle); from attempt 3 assume the inputNode is stale and rebuild.
            if attempt >= 3 {
                engine = AVAudioEngine()
                preferredDevice = Self.resolveInputDevice(preferredUID: preferredDeviceUID)
                Log.audio.notice("Replaced AVAudioEngine instance for attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public)")
            }
            let inputNode = engine.inputNode
            applyPreferredInputDevice(preferredDevice, to: inputNode)

            // Re-read the live input format each attempt; a prior failed start may
            // have flipped the device into a new sample rate.
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw AudioEngineError.inputUnavailable
            }

            // `format: nil` taps the node's *live* format at install time; the
            // converter is built lazily in `handleTap` from the buffer's actual
            // format, so a rate change after this point is still handled.
            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { [weak self] buffer, _ in
                self?.handleTap(buffer: buffer, levelCallback: levelCallback)
            }
            stateQueue.sync { tapInstalled = true }

            do {
                try engine.start()
                Log.audio.notice("Engine started (attempt \(attempt, privacy: .public))")
                Log.pipelineSignpost.emitEvent("engine-started")
                return
            } catch {
                lastError = error
                inputNode.removeTap(onBus: 0)
                stateQueue.sync { tapInstalled = false }
                engine.reset()
                Log.audio.notice(
                    "Engine start attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public) failed at input rate \(inputFormat.sampleRate, privacy: .public) Hz (\(error.localizedDescription, privacy: .public)); retrying after route settles"
                )
                if attempt < maxAttempts {
                    // Let the provoked Bluetooth route change settle before retrying.
                    // Doubling backoff (0.2/0.4/0.8s): HFP switches routinely take
                    // longer than the old fixed 0.2s window. Task.sleep (not
                    // Thread.sleep) so the caller's actor isn't held hostage — a
                    // quick key release must be able to run stop/cancel meanwhile.
                    try? await Task.sleep(nanoseconds: UInt64(0.2 * pow(2.0, Double(attempt - 1)) * 1_000_000_000))
                }
            }
        }

        throw lastError ?? AudioEngineError.inputUnavailable
    }

    /// The device to bind for this capture: the user's selected mic when its
    /// UID still resolves, otherwise the current system default. Returns nil
    /// only when no input device exists at all.
    private static func resolveInputDevice(preferredUID: String) -> AudioDeviceID? {
        if let selected = AudioDeviceManager.deviceID(forUID: preferredUID) {
            return selected
        }
        return AudioDeviceManager.defaultInputDeviceID()
    }

    private func handleTap(
        buffer: AVAudioPCMBuffer,
        levelCallback: @escaping @MainActor @Sendable ([Float]) -> Void
    ) {
        let (cachedConverter, cachedInputFormat, targetFormat, isOverflowed) = stateQueue.sync {
            // First delivered buffer marks the true start of capture. Only set
            // when nil so a mid-capture recovery restart keeps the original
            // clock; `stopCapture`/start-failure rollback clear it.
            if recordingStartTime == nil {
                recordingStartTime = Date()
            }
            return (currentConverter, currentInputFormat, currentTargetFormat, overflowed)
        }
        guard !isOverflowed else { return }
        guard let targetFormat = targetFormat else { return }

        let inputFormat = buffer.format
        guard inputFormat.sampleRate > 0 else { return }

        // Build (or rebuild) the converter from the buffer's *actual* format. The
        // live input rate can differ from what the node reported at install time —
        // and Bluetooth devices may change it mid-recording — so key the cached
        // converter on the format we last saw.
        let converter: AVAudioConverter
        if let cachedConverter = cachedConverter, cachedInputFormat == inputFormat {
            converter = cachedConverter
        } else {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                Log.audio.error("Failed to create converter for input format \(inputFormat, privacy: .public)")
                fireInterruption(.conversionFailed("Unsupported input format"))
                return
            }
            stateQueue.sync {
                currentConverter = newConverter
                currentInputFormat = inputFormat
            }
            converter = newConverter
        }

        let frameCapacity = AVAudioFrameCount(
            max(1, ceil(Double(buffer.frameLength) * self.targetSampleRate / inputFormat.sampleRate))
        )
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            return
        }

        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            Log.audio.error("Audio converter failed: \(error.localizedDescription, privacy: .public)")
            fireInterruption(.conversionFailed(error.localizedDescription))
            return
        }

        guard let channelData = converted.floatChannelData else { return }
        let frameLength = Int(converted.frameLength)
        guard frameLength > 0 else { return }

        let byteCount = frameLength * MemoryLayout<Float>.size
        let samples = channelData[0]

        var didOverflow = false
        stateQueue.sync {
            let projected = audioBuffer.count + byteCount
            if projected > AudioEngine.maxBufferBytes {
                overflowed = true
                didOverflow = true
                return
            }
            samples.withMemoryRebound(to: UInt8.self, capacity: byteCount) { bytes in
                audioBuffer.append(bytes, count: byteCount)
            }
        }

        if didOverflow {
            Log.audio.error("Audio buffer exceeded \(AudioEngine.maxBufferBytes) bytes — stopping capture")
            fireInterruption(.bufferOverflow)
            return
        }

        let levels = computeLevels(from: samples, count: frameLength)
        Task { @MainActor in
            levelCallback(levels)
        }
    }

    private func fireInterruption(_ reason: AudioEngineInterruption) {
        // Always deliver on main so the pipeline can mutate UI state safely.
        let handler = interruptionHandler
        DispatchQueue.main.async {
            handler?(reason)
        }
    }

    private func installObservers() {
        let nc = NotificationCenter.default
        // object: nil, not the current engine — the instance can be replaced
        // during -10868 recovery, and an observer bound to the old instance
        // would silently stop firing. This is the app's only AVAudioEngine.
        configObserver = nc.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Log.audio.notice("AVAudioEngine configuration change — attempting recovery")
            self.handleConfigurationChange()
        }

        let wsNC = NSWorkspace.shared.notificationCenter
        sleepObserver = wsNC.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Log.audio.notice("System will sleep — tearing down capture")
            self.tearDown(reason: .systemSleep)
        }
    }

    private func removeObservers() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        if let observer = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            sleepObserver = nil
        }
    }

    /// Routes capture to the resolved microphone (user-selected, or the system
    /// default via `resolveInputDevice`). nil — no input device at all — leaves
    /// the AUHAL binding untouched.
    private func applyPreferredInputDevice(_ deviceID: AudioDeviceID?, to inputNode: AVAudioInputNode) {
        guard let deviceID,
              let audioUnit = inputNode.audioUnit else { return }
        var mutableID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            Log.audio.error("Failed to set input device (\(status, privacy: .public)); using default")
            return
        }

        // Switching `CurrentDevice` flips the underlying device but leaves the
        // AUHAL's cached output stream format at the previous device's rate
        // (e.g. 48 kHz). A `format: nil` tap then adopts that stale rate while
        // the new device runs at, say, 44.1 kHz — graph init aborts with -10868
        // before any buffer arrives. Re-point the node's output format at the
        // new device's actual rate so the tap and graph agree.
        reconcileInputFormat(audioUnit)
    }

    /// Make the input AUHAL's client (output-scope) format on the input element
    /// match the device's live hardware format, so `inputNode.outputFormat(forBus:0)`
    /// — and the `format: nil` tap built from it — agree with the HW. Without this,
    /// a device switch leaves the client format at the prior device's rate (e.g.
    /// 48 kHz over a 44.1 kHz HW input) and graph init aborts with -10868.
    ///
    /// AUHAL element 1 is the input (microphone) bus: input scope = the hardware
    /// format, output scope = the format delivered to the app. (Element 0 is the
    /// disabled speaker bus — setting a format there returns -10868.)
    private func reconcileInputFormat(_ audioUnit: AudioUnit) {
        let inputElement: AudioUnitElement = 1

        // Read the true hardware format off the input scope of the input element.
        var hwFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let getStatus = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            inputElement,
            &hwFormat,
            &size
        )
        guard getStatus == noErr, hwFormat.mSampleRate > 0 else {
            Log.audio.error("Failed to read HW input format (\(getStatus, privacy: .public))")
            return
        }

        // Read the current client format; skip if the sample rate already agrees.
        var clientFormat = AudioStreamBasicDescription()
        var clientSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            inputElement,
            &clientFormat,
            &clientSize
        ) == noErr else { return }
        guard clientFormat.mSampleRate != hwFormat.mSampleRate else { return }

        // Match the client rate to HW; keep our existing channel/packetisation by
        // copying only the sample rate (AVAudioEngine derives the rest).
        clientFormat.mSampleRate = hwFormat.mSampleRate
        let setStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            inputElement,
            &clientFormat,
            clientSize
        )
        if setStatus != noErr {
            // Non-fatal: fall through to the retry loop, which may still settle.
            Log.audio.error("Failed to set client input format to \(hwFormat.mSampleRate, privacy: .public) Hz (\(setStatus, privacy: .public))")
        } else {
            Log.audio.notice("Reconciled input format to \(hwFormat.mSampleRate, privacy: .public) Hz")
        }
    }

    /// Release the input node's device binding by pointing the AUHAL at
    /// `kAudioObjectUnknown`. Without this, the engine keeps the chosen device
    /// claimed after `stop()`, which parks Bluetooth mics (e.g. AirPods) in
    /// degraded 24 kHz HFP — system audio stays muffled until something else
    /// resets the route. Releasing the binding lets macOS return them to
    /// high-quality A2DP. Harmless for wired/built-in devices (resets to default).
    private func unbindInputDevice() {
        guard let audioUnit = engine.inputNode.audioUnit else { return }
        var unknown = AudioDeviceID(kAudioObjectUnknown)
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &unknown,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            Log.audio.error("Failed to unbind input device (\(status, privacy: .public))")
        }
    }

    /// Handle an `AVAudioEngineConfigurationChange`. This fires both when the
    /// user genuinely swaps the active device mid-recording AND when a freshly
    /// engaged Bluetooth route is still settling — AirPods flip into 24 kHz HFP a
    /// beat *after* `engine.start()` returned, emitting this notification once the
    /// switch completes. Apple requires the engine be restarted after this
    /// notification, so rather than abort, rebuild the tap on the new route and
    /// restart capture (the buffer continues, the converter rebuilds lazily from
    /// the new format). Only if the restart fails — device truly gone — do we
    /// surface `.deviceChanged`.
    private func handleConfigurationChange() {
        let proceed = stateQueue.sync { () -> Bool in
            guard tapInstalled, !isRecovering else { return false }
            isRecovering = true
            return true
        }
        guard proceed else { return }

        let (callback, uid, generation) = stateQueue.sync {
            (levelCallback, preferredDeviceUID, captureGeneration)
        }
        guard let callback = callback else {
            stateQueue.sync { isRecovering = false }
            return
        }

        // Off the main actor: the settle wait + retry must not stall the UI
        // run loop. Detached so it doesn't inherit the notification's context.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            // Coalesce the burst of notifications a single route switch emits, and
            // let the route reach its final format before we re-read it.
            try? await Task.sleep(nanoseconds: 150_000_000)

            // Bail if capture ended (stop/teardown) while we were waiting.
            guard self.stateQueue.sync(execute: { self.captureGeneration }) == generation else {
                self.stateQueue.sync { self.isRecovering = false }
                return
            }

            if self.stateQueue.sync(execute: { self.tapInstalled }) {
                self.engine.inputNode.removeTap(onBus: 0)
                self.stateQueue.sync { self.tapInstalled = false }
            }
            self.engine.reset()

            do {
                try await self.startEngineWithRetry(preferredDeviceUID: uid, levelCallback: callback)
                // stopCapture/tearDown may have run during the restart window; if so,
                // unwind the engine we just brought back up instead of leaving it live.
                let stale = self.stateQueue.sync(execute: { self.captureGeneration }) != generation
                if stale {
                    self.engine.inputNode.removeTap(onBus: 0)
                    if self.engine.isRunning { self.engine.stop() }
                    self.stateQueue.sync {
                        self.tapInstalled = false
                        self.isRecovering = false
                    }
                    return
                }
                Log.audio.notice("Recovered capture after configuration change")
                self.stateQueue.sync { self.isRecovering = false }
            } catch {
                Log.audio.error("Failed to recover after configuration change: \(error.localizedDescription, privacy: .public)")
                self.stateQueue.sync { self.isRecovering = false }
                self.tearDown(reason: .deviceChanged)
            }
        }
    }

    /// Force-stop the engine and notify the pipeline with `reason`.
    private func tearDown(reason: AudioEngineInterruption) {
        let tapped = stateQueue.sync { tapInstalled }
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
        }
        unbindInputDevice()
        if engine.isRunning {
            engine.stop()
        }
        stateQueue.sync {
            tapInstalled = false
            isRecovering = false
            captureGeneration += 1
            levelCallback = nil
        }
        removeObservers()

        let handler = interruptionHandler
        handler?(reason)
    }

    @discardableResult
    func stopCapture() -> Data {
        let tapped = stateQueue.sync { tapInstalled }
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
        }
        unbindInputDevice()
        if engine.isRunning {
            engine.stop()
        }
        removeObservers()
        interruptionHandler = nil

        return stateQueue.sync {
            tapInstalled = false
            isRecovering = false
            captureGeneration += 1
            levelCallback = nil
            let result = audioBuffer
            audioBuffer = Data()
            recordingStartTime = nil
            currentConverter = nil
            currentInputFormat = nil
            currentTargetFormat = nil
            overflowed = false
            return result
        }
    }

    private func computeLevels(from samples: UnsafePointer<Float>, count: Int, barCount: Int = 15) -> [Float] {
        guard count > 0 else { return Array(repeating: 0, count: barCount) }

        let chunkSize = max(count / barCount, 1)
        var levels = Array(repeating: Float(0), count: barCount)

        for i in 0..<barCount {
            let start = i * chunkSize
            let end = min(start + chunkSize, count)
            guard start < end else { continue }

            var rms: Float = 0
            vDSP_measqv(samples.advanced(by: start), 1, &rms, vDSP_Length(end - start))
            rms = sqrtf(rms)

            let normalized = min(rms * 5.0, 1.0)
            levels[i] = normalized
        }

        return levels
    }

    deinit {
        removeObservers()
        if engine.isRunning { engine.stop() }
    }
}

enum AudioEngineError: Error, LocalizedError {
    case alreadyRecording
    case formatCreationFailed
    case converterCreationFailed
    case inputUnavailable
    /// Capture was stopped (quick release / teardown) while the engine start
    /// was still settling a route change — not a user-visible failure.
    case startAborted

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "Recording is already in progress"
        case .formatCreationFailed: return "Failed to create target audio format"
        case .converterCreationFailed: return "Failed to create audio converter"
        case .inputUnavailable: return "Microphone input is unavailable"
        case .startAborted: return "Capture start aborted by stop"
        }
    }
}
