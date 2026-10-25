import Foundation

struct DiarizationSummary: Equatable, Codable, Sendable {
    struct Span: Equatable, Codable, Sendable {
        let speakerID: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let isKept: Bool

        init(
            speakerID: String,
            startTime: TimeInterval,
            endTime: TimeInterval,
            isKept: Bool = false
        ) {
            self.speakerID = speakerID
            self.startTime = startTime
            self.endTime = endTime
            self.isKept = isKept
        }

        var duration: TimeInterval {
            max(0, endTime - startTime)
        }
    }

    struct MergedSpan: Equatable, Codable, Sendable {
        let startTime: TimeInterval
        let endTime: TimeInterval

        init(startTime: TimeInterval, endTime: TimeInterval) {
            self.startTime = startTime
            self.endTime = endTime
        }

        var duration: TimeInterval {
            max(0, endTime - startTime)
        }
    }

    enum FallbackReason: String, Equatable, Codable, Sendable {
        case noUsableSpeakerSpans
        case noSpeakerReachedThreshold
        case ambiguousDominantSpeaker
        case singleDetectedSpeaker
        case insufficientKeptAudio
        case filteredAudioExtractionFailed
        case emptyFilteredTranscription
    }

    let spans: [Span]
    let mergedKeptSpans: [MergedSpan]
    let targetSpeakerID: String?
    let targetSpeakerDuration: TimeInterval
    let keptAudioDuration: TimeInterval
    let usedFallback: Bool
    let fallbackReason: FallbackReason?

    init(
        spans: [Span],
        mergedKeptSpans: [MergedSpan],
        targetSpeakerID: String?,
        targetSpeakerDuration: TimeInterval,
        keptAudioDuration: TimeInterval,
        usedFallback: Bool,
        fallbackReason: FallbackReason?
    ) {
        self.spans = spans
        self.mergedKeptSpans = mergedKeptSpans
        self.targetSpeakerID = targetSpeakerID
        self.targetSpeakerDuration = targetSpeakerDuration
        self.keptAudioDuration = keptAudioDuration
        self.usedFallback = usedFallback
        self.fallbackReason = fallbackReason
    }
}

struct SpeakerTaggedTranscript: Equatable, Sendable {
    struct Attribution: Codable, Equatable, Sendable {
        enum Source: String, Codable, Equatable, Sendable {
            case diarization
            case singleSpeakerFallback
            case userAssignedIdentity
        }

        let speakerID: String
        let recognizedVoiceID: UUID?
        let displayName: String?
        let confidence: Double
        let evidenceDuration: TimeInterval
        let source: Source

        init(
            speakerID: String,
            recognizedVoiceID: UUID? = nil,
            displayName: String? = nil,
            confidence: Double,
            evidenceDuration: TimeInterval,
            source: Source
        ) {
            self.speakerID = speakerID
            self.recognizedVoiceID = recognizedVoiceID
            self.displayName = displayName
            self.confidence = min(1, max(0, confidence))
            self.evidenceDuration = max(0, evidenceDuration)
            self.source = source
        }

        static func == (lhs: Attribution, rhs: Attribution) -> Bool {
            lhs.speakerID == rhs.speakerID &&
                lhs.recognizedVoiceID == rhs.recognizedVoiceID &&
                lhs.displayName == rhs.displayName &&
                abs(lhs.confidence - rhs.confidence) < 0.0001 &&
                abs(lhs.evidenceDuration - rhs.evidenceDuration) < 0.0001 &&
                lhs.source == rhs.source
        }
    }

    struct Segment: Equatable, Sendable {
        let speakerID: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let text: String
        let attribution: Attribution

        init(
            speakerID: String,
            startTime: TimeInterval,
            endTime: TimeInterval,
            text: String,
            attribution: Attribution? = nil
        ) {
            self.speakerID = speakerID
            self.startTime = startTime
            self.endTime = endTime
            self.text = text
            self.attribution = attribution ?? Attribution(
                speakerID: speakerID,
                confidence: 1,
                evidenceDuration: max(0, endTime - startTime),
                source: .diarization
            )
        }
    }

    let segments: [Segment]
}

struct SpeakerTaggedTranscriptionResult: Equatable, Sendable {
    let filteredTranscript: String?
    let diarizationSummary: DiarizationSummary
    let speakerTaggedTranscript: SpeakerTaggedTranscript?
}
