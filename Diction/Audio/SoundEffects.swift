import AppKit

/// Start, stop and hands-free sounds: macOS's own system sounds, so the app ships no audio files.
class SoundEffects {
    private let startSound = NSSound(named: "Tink")
    private let stopSound = NSSound(named: "Pop")
    private let lockSound = NSSound(named: "Morse")
    private let isEnabled: () -> Bool
    private let startPlayer: () -> Void
    private let stopPlayer: () -> Void

    init(
        isEnabled: @escaping () -> Bool = { true },
        startPlayer: (() -> Void)? = nil,
        stopPlayer: (() -> Void)? = nil
    ) {
        self.isEnabled = isEnabled
        self.startPlayer = startPlayer ?? { [startSound] in
            startSound?.stop()
            startSound?.play()
        }
        self.stopPlayer = stopPlayer ?? { [stopSound] in
            stopSound?.stop()
            stopSound?.play()
        }
    }

    func playStart() {
        guard isEnabled() else { return }
        startPlayer()
    }

    func playStop() {
        guard isEnabled() else { return }
        stopPlayer()
    }

    /// Hands-free mode just locked on.
    func playLock() {
        guard isEnabled() else { return }
        lockSound?.stop()
        lockSound?.play()
    }
}
