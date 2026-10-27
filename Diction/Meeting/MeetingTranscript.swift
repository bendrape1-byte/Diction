import Foundation

/// A person attending a meeting (from calendar invite or OCR-detected).
struct MeetingAttendee: Hashable, Codable {
    let name: String
    let declined: Bool

    init(name: String, declined: Bool = false) {
        self.name = name
        self.declined = declined
    }
}

/// Identifies who is speaking in a transcript segment.
enum SpeakerLabel: Codable, Equatable {
    case me
    case remote(name: String?)

    var displayName: String {
        switch self {
        case .me:
            return "Me"
        case .remote(let name):
            return name ?? "Others"
        }
    }
}

/// A single timestamped segment of transcribed speech.
struct TranscriptSegment: Codable, Identifiable {
    let id: UUID
    let speaker: SpeakerLabel
    let startTime: TimeInterval // seconds since meeting start
    let endTime: TimeInterval
    var text: String

    /// Formatted timestamp string like "02:15" or "1:02:15".
    var formattedTimestamp: String {
        let total = Int(startTime)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct MeetingSpeakerReviewItem: Equatable, Identifiable {
    let id: String
    let displayName: String
    let segmentCount: Int
    let firstTimestamp: String
    let sampleText: String
    let recognizedVoiceID: UUID?
    let isVoicePrintBacked: Bool
    let isMe: Bool
}

/// Observable model for a meeting transcript with notes and metadata.
@MainActor
final class MeetingTranscript: ObservableObject {
    @Published var meetingName: String
    @Published var startDate: Date
    @Published var endDate: Date?
    @Published var notes: String
    @Published var segments: [TranscriptSegment]
    @Published var attendees: [MeetingAttendee]
    @Published var summary: String?
    @Published var isGeneratingSummary = false
    /// Saved article body for Reader entries. When non-nil, this entry is treated
    /// as a reader (Article + Notes tabs) instead of a meeting (Notes + Transcript + Summary).
    @Published var articleBody: String?
    var importedFrom: String?
    /// One sentence on what the meeting was about, for INDEX.md. Nil until Haiku writes it; the title stands in.
    var meetingDescription: String?
    /// Optional source URL — used by Reader entries.
    var sourceURL: String?

    let sessionID: UUID

    init(
        meetingName: String,
        startDate: Date = Date(),
        sessionID: UUID = UUID()
    ) {
        self.meetingName = meetingName
        self.startDate = startDate
        self.sessionID = sessionID
        self.notes = ""
        self.segments = []
        self.attendees = []
    }

    func appendSegment(_ segment: TranscriptSegment) {
        segments.append(segment)
    }

    func replaceSpeakerDisplayName(_ currentName: String, with newName: String) {
        let normalizedCurrentName = currentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNewName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCurrentName.isEmpty, !normalizedNewName.isEmpty else {
            return
        }

        segments = segments.map { segment in
            guard segment.speaker.displayName == normalizedCurrentName else {
                return segment
            }

            return TranscriptSegment(
                id: segment.id,
                speaker: segment.speaker == .me ? .me : .remote(name: normalizedNewName),
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text
            )
        }
    }

    /// Duration of the meeting so far, in seconds.
    var duration: TimeInterval {
        let end = endDate ?? Date()
        return end.timeIntervalSince(startDate)
    }

    /// Formatted duration like "45m" or "1h 12m".
    var formattedDuration: String {
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

// MARK: - Summary

/// Asks Claude Haiku for a finished meeting's one-sentence description and a short summary.
/// The transcript text leaves the Mac; the audio never does. An hour of talk is about 15k tokens, one request.
enum MeetingSummarizer {
    private static let instructions = """
        You get the transcript of a meeting. "Me" is the person who recorded it. Reply with:
        - description: one sentence (at most 25 words) saying what the meeting was about, so someone scanning a list \
        of meetings can tell whether this is the one they need. Name the people, project or topic.
        - summary: 3 to 8 short bullet points covering decisions made, action items (with who does them, when the \
        transcript says), and open questions. Leave out small talk. Only state what the transcript supports.
        Write in the language most of the meeting was in. The transcript comes from speech recognition, so expect \
        misheard words and repeated lines.
        """

    @MainActor
    static func summarize(_ transcript: MeetingTranscript, key: String) async throws {
        let text = transcript.segments
            .map { "[\($0.formattedTimestamp)] \($0.speaker.displayName): \($0.text)" }
            .joined(separator: "\n")

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120  // the cleanup session's 5 s is far too short for a long meeting
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": "claude-haiku-5-5",
            "max_tokens": 1024,
            "thinking": ["type": "disabled"],
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": [
                    "type": "object",
                    "properties": [
                        "description": ["type": "string"],
                        "summary": ["type": "array", "items": ["type": "string"]],
                    ],
                    "required": ["description", "summary"], "additionalProperties": false,
                ]],
            ],
            "system": instructions,
            "messages": [["role": "user", "content": "Meeting: \(transcript.meetingName)\n\n\(text)"]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let blocks = json?["content"] as? [[String: Any]] ?? []
        let raw = blocks.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
        let answer = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        let description = (answer?["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let bullets = (answer?["summary"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !description.isEmpty, !bullets.isEmpty else { throw URLError(.cannotParseResponse) }

        transcript.meetingDescription = description
        transcript.summary = bullets.map { "- \($0)" }.joined(separator: "\n")
    }
}
