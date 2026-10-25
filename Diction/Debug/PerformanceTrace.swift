import Foundation

struct PerformanceTrace {
    let sessionID: String
    let startedAt: Date

    var hotkeyDetectedAt: Date?
    var micLiveAt: Date?
    var hotkeyLiftedAt: Date?
    var micColdAt: Date?
    var transcriptionStartAt: Date?
    var transcriptionEndAt: Date?
    var cleanupStartAt: Date?
    var cleanupEndAt: Date?
    var ocrCaptureDuration: TimeInterval?
    var promptBuildDuration: TimeInterval?
    var modelCallDuration: TimeInterval?
    var postProcessDuration: TimeInterval?
    var pasteStartAt: Date?
    var pasteEndAt: Date?

    init(sessionID: String, startedAt: Date = Date()) {
        self.sessionID = sessionID
        self.startedAt = startedAt
    }

    func summary(
        speechModelID: String,
        cleanupBackend: CleanupBackendOption,
        cleanupAttempted: Bool
    ) -> String {
        let parts = [
            "session=\(sessionID)",
            "speechModel=\(speechModelID)",
            "cleanupBackend=\(cleanupBackend.rawValue)",
            "hotkey_to_mic_live=\(duration(from: hotkeyDetectedAt, to: micLiveAt))",
            "hotkey_lift_to_mic_cold=\(duration(from: hotkeyLiftedAt, to: micColdAt))",
            "transcription=\(duration(from: transcriptionStartAt, to: transcriptionEndAt))",
            cleanupAttempted
                ? "cleanup=\(duration(from: cleanupStartAt, to: cleanupEndAt))"
                : "cleanup=skipped",
            cleanupAttempted
                ? "ocr=\(duration(ocrCaptureDuration))"
                : "ocr=skipped",
            cleanupAttempted
                ? "prompt_build=\(duration(promptBuildDuration))"
                : "prompt_build=skipped",
            cleanupAttempted
                ? "model_call=\(duration(modelCallDuration))"
                : "model_call=skipped",
            cleanupAttempted
                ? "post_process=\(duration(postProcessDuration))"
                : "post_process=skipped",
            "paste=\(duration(from: pasteStartAt, to: pasteEndAt))",
            "total=\(duration(from: startedAt, to: pasteEndAt))"
        ]

        return parts.joined(separator: " ")
    }

    private func duration(from start: Date?, to end: Date?) -> String {
        guard let start, let end else {
            return "n/a"
        }

        return Self.format(duration: end.timeIntervalSince(start))
    }

    private func duration(from start: Date, to end: Date?) -> String {
        guard let end else {
            return "n/a"
        }

        return Self.format(duration: end.timeIntervalSince(start))
    }

    private func duration(_ duration: TimeInterval?) -> String {
        guard let duration else {
            return "n/a"
        }

        return Self.format(duration: duration)
    }

    private static func format(duration: TimeInterval) -> String {
        "\(Int((duration * 1000).rounded()))ms"
    }
}
