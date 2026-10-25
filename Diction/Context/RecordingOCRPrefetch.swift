import Foundation

struct RecordingOCRPrefetchResult {
    let context: OCRContext?
    let elapsed: TimeInterval
}

@MainActor
final class RecordingOCRPrefetch {
    typealias Capture = @Sendable ([String]) async -> OCRContext?

    private let capture: Capture
    private var task: Task<RecordingOCRPrefetchResult, Never>?

    init(capture: @escaping Capture) {
        self.capture = capture
    }

    func start(customWords: [String]) {
        cancel()
        task = Task {
            let start = Date()
            let context = await capture(customWords)
            return RecordingOCRPrefetchResult(
                context: context,
                elapsed: Date().timeIntervalSince(start)
            )
        }
    }

    func resolve() async -> RecordingOCRPrefetchResult? {
        guard let task else {
            return nil
        }

        let result = await task.value
        self.task = nil
        return result
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
