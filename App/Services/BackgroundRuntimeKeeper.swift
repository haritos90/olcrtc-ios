import AVFoundation
import Foundation

// MARK: - BackgroundRuntimeKeeper
//
// Keeps the app alive in the iOS background by playing a silent looping
// audio buffer through AVAudioEngine.
//
// Why this approach?
// iOS suspends apps within a few seconds of backgrounding unless they hold
// an active background task (audio, location, VoIP, …). Playing silent audio
// with the `mixWithOthers` option is the lightest way to stay alive without
// interfering with the user's music or podcasts. The alternative is
// NEPacketTunnelProvider (VPN), deferred until we have a paid dev account.
//
// Requires `UIBackgroundModes: [audio]` in Info.plist (set via project.yml).
//
// Usage: call start() when the tunnel connects; stop() when it disconnects.
// start() is idempotent — calling it twice is safe.
//
// #432: resilience. A silent-audio keep-alive dies on two events the OS raises
// routinely — an AVAudioSession *interruption* (a phone call, Siri, another app
// grabbing audio) and a *media-services reset* — and nothing here used to bring it
// back, so after the first phone call the app silently became suspendable again
// (the tunnel/SOCKS then died in the background and logging stopped, with no trace
// of why). The keeper now observes both, re-arms the engine when it can, and logs
// every transition to the connection log so "why did my app suspend?" is
// answerable from the Logs tab alone.

@MainActor
final class BackgroundRuntimeKeeper {
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var silentBuffer: AVAudioPCMBuffer?
    private var running = false
    private var observers: [NSObjectProtocol] = []

    /// #432: exposed so the app-lifecycle logging can report whether keep-alive is
    /// actually holding the app up when it backgrounds.
    var isRunning: Bool { running }

    func start() throws {
        guard !running else { return }
        try armSession()
        try buildAndPlay()
        running = true
        installObservers()   // #432: only while running; removed in stop()
    }

    /// #432: activate the audio session (idempotent — also used on interruption
    /// recovery, where the engine is rebuilt separately).
    private func armSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, options: [.mixWithOthers])
        try session.setActive(true)
    }

    /// #432: (re)build the engine graph and start the silent loop. Split out of
    /// `start()` so interruption/reset recovery can rebuild from scratch — a reset
    /// invalidates the old engine and player entirely.
    private func buildAndPlay() throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            throw BackgroundError.invalidFormat
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0

        // 1-second silent buffer, looped forever.
        let frameCount = AVAudioFrameCount(44_100)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            engine.detach(player)
            throw BackgroundError.bufferAllocationFailed
        }
        buffer.frameLength = frameCount
        // PCM data is zero-initialised = digital silence.

        silentBuffer = buffer
        do {
            try engine.start()
        } catch {
            engine.detach(player)
            silentBuffer = nil
            throw error
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
    }

    // MARK: Interruption / reset resilience (#432)

    /// What to do for an AVAudioSession interruption notification. Pure so the
    /// decision is unit-testable without a live audio session.
    enum InterruptionAction: Equatable { case pause, resume, ignore }
    nonisolated static func interruptionAction(began: Bool, shouldResume: Bool) -> InterruptionAction {
        began ? .pause : (shouldResume ? .resume : .ignore)
    }

    private func installObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaReset() }
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard running,
              let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let began = type == .began
        let optsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optsRaw).contains(.shouldResume)

        switch Self.interruptionAction(began: began, shouldResume: shouldResume) {
        case .pause:
            LogStore.shared.log(.connection,
                "⚠ keep-alive: audio interrupted — app may suspend until it resumes", level: .warn)
        case .resume:
            do {
                try armSession()
                if !engine.isRunning { player.play(); try engine.start() }
                LogStore.shared.log(.connection, "✓ keep-alive: audio resumed after interruption")
            } catch {
                LogStore.shared.log(.connection,
                    "⚠ keep-alive: could not resume audio after interruption (\(error.localizedDescription))",
                    level: .warn)
            }
        case .ignore:
            // Interruption ended without a resume hint — leave the engine as-is; a
            // later background/foreground cycle re-arms it.
            break
        }
    }

    private func handleMediaReset() {
        guard running else { return }
        LogStore.shared.log(.connection, "⚠ keep-alive: media services reset — rebuilding audio", level: .warn)
        // A reset invalidates the whole audio stack; start over with fresh objects.
        player.stop(); engine.stop(); engine.detach(player)
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        silentBuffer = nil
        do {
            try armSession()
            try buildAndPlay()
            LogStore.shared.log(.connection, "✓ keep-alive: audio rebuilt after media reset")
        } catch {
            running = false
            LogStore.shared.log(.connection,
                "⚠ keep-alive: audio rebuild failed after media reset (\(error.localizedDescription)) — app may suspend",
                level: .warn)
        }
    }

    enum BackgroundError: LocalizedError {
        case invalidFormat
        case bufferAllocationFailed

        var errorDescription: String? {
            switch self {
            case .invalidFormat:          return "AVAudioFormat creation failed"
            case .bufferAllocationFailed: return "AVAudioPCMBuffer allocation failed"
            }
        }
    }

    func stop() {
        guard running else { return }
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
        player.stop()
        engine.stop()
        engine.detach(player)
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
        silentBuffer = nil
        running = false
    }
}
