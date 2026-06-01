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

@MainActor
final class BackgroundRuntimeKeeper {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var silentBuffer: AVAudioPCMBuffer?
    private var running = false

    func start() throws {
        guard !running else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, options: [.mixWithOthers])
        try session.setActive(true)

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
        running = true
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
        player.stop()
        engine.stop()
        engine.detach(player)
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
        silentBuffer = nil
        running = false
    }
}
