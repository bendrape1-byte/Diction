import AppKit
import Foundation

// Data behind the Diction window: every dictation, the snippets, the one style applied before pasting,
// and the spiral that draws everything said.

struct DictationRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    let date: Date
    let text: String   // what was pasted
    let raw: String    // what the speech model heard

    var words: Int { text.split(whereSeparator: \.isWhitespace).count }
}

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: String
    var expansion: String
}

enum StyleChoice: String, CaseIterable {
    case formal, casual, veryCasual, excited

    /// One style for every app. Older versions kept one per kind of app; the "other apps" one carries over.
    static var current: StyleChoice {
        get {
            let d = UserDefaults.standard
            return StyleChoice(rawValue: d.string(forKey: "style") ?? d.string(forKey: "style.other") ?? "") ?? .formal
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "style") }
    }
}

enum StyleFormatter {
    /// Done after cleanup instead of in the prompt (so the Haiku prompt cache stays the same):
    /// formal = as cleaned, casual = no final period, very casual = also lower-case sentence starts,
    /// excited = final period becomes "!".
    static func apply(_ text: String, style: StyleChoice) -> String {
        guard !text.isEmpty else { return text }
        switch style {
        case .formal:
            return text
        case .casual:
            return text.hasSuffix(".") && !text.hasSuffix("..") ? String(text.dropLast()) : text
        case .veryCasual:
            var chars = Array(apply(text, style: .casual))
            var sentenceStart = true
            for i in chars.indices {
                if sentenceStart, chars[i].isLetter {
                    // only before a lower-case letter, so "I", "I'm" and "AI" stay as they are
                    let next = i + 1 < chars.count ? chars[i + 1] : " "
                    if next.isLetter, next.isLowercase { chars[i] = Character(chars[i].lowercased()) }
                    sentenceStart = false
                } else if ".!?\n".contains(chars[i]) {
                    sentenceStart = true
                }
            }
            return String(chars)
        case .excited:
            return text.hasSuffix(".") && !text.hasSuffix("..") ? String(text.dropLast()) + "!" : text
        }
    }
}

enum SnippetExpander {
    /// Replaces each spoken trigger with its text. If the whole dictation is just the trigger
    /// (cleanup may add a period or capital letter), only the snippet text is pasted.
    static func expand(_ text: String, snippets: [Snippet]) -> String {
        var out = text
        for s in snippets where !s.trigger.trimmingCharacters(in: .whitespaces).isEmpty {
            let bare = out.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,; ").union(.whitespacesAndNewlines))
            if bare.caseInsensitiveCompare(s.trigger) == .orderedSame { return s.expansion }
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: s.trigger) + "\\b"
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: s.expansion))
        }
        return out
    }
}

/// Every dictation on one spiral line, oldest in the middle. A dictation takes a stretch of line as long as the
/// square root of its word count, each word bends the line out or in by its length, and a new day leaves a small gap.
enum Spiral {
    /// One polyline per dictation (oldest first), inside a square of `size` points.
    // ponytail: rebuilt in full on every change, a few ms for 2,500 dictations; append-only updates if it ever lags
    static func segments(_ dictations: [DictationRecord], size: CGFloat) -> [[CGPoint]] {
        let records = dictations.sorted { $0.date < $1.date }
        let r0: CGFloat = 11, b: CGFloat = 3.3 / (2 * .pi), c = size / 2
        let theta = { (s: CGFloat) in (-r0 + (r0 * r0 + 2 * b * s).squareRoot()) / b }  // inverse of arc length r0*t + b*t²/2
        let tMax = (size / 2 - 2 - r0) / b
        let sMax = r0 * tMax + b * tMax * tMax / 2
        let days = records.map { Calendar.current.startOfDay(for: $0.date) }
        let newDay = { (i: Int) in i > 0 && days[i] != days[i - 1] }
        var weight: CGFloat = 0
        for (i, d) in records.enumerated() { weight += CGFloat(Double(d.words).squareRoot()) + 0.5 + (newDay(i) ? 1.4 : 0) }
        guard weight > 0 else { return [] }
        let unit = sMax * 0.965 / weight  // the outer edge stays free for what comes next
        var s: CGFloat = 0
        return records.enumerated().map { i, d in
            if newDay(i) { s += 1.4 * unit }
            let lens = d.text.split(whereSeparator: \.isWhitespace).prefix(24).map { CGFloat(min($0.count, 15)) }
            let bend = { (k: Int) in lens.isEmpty ? 0 : max(-1.1, min(1.1, (lens[min(k, lens.count - 1)] - 4.6) * 0.26)) }
            let len = CGFloat(Double(d.words).squareRoot()) * unit
            let n = max(2, Int((len / 0.7).rounded(.up)))
            let points = (0...n).map { j -> CGPoint in
                let u = CGFloat(j) / CGFloat(n)
                let f = u * CGFloat(max(lens.count - 1, 0)), k = Int(f), w = f - CGFloat(k)
                let out = lens.count < 2 ? 0 : (bend(k) + (bend(k + 1) - bend(k)) * (1 - cos(w * .pi)) / 2) * sin(.pi * u)
                let t = theta(s + len * u), r = r0 + b * t + out
                return CGPoint(x: c + r * cos(t - .pi / 2), y: c + r * sin(t - .pi / 2))
            }
            s += len + 0.5 * unit
            return points
        }
    }
}

@MainActor
final class HubStore: ObservableObject {
    static let shared = HubStore()

    @Published private(set) var dictations: [DictationRecord] = [] { didSet { spiralCache = nil } }  // newest first
    @Published private(set) var totalWords = 0
    @Published var snippets: [Snippet] = [] { didSet { save(snippets, "snippets.json") } }

    private var spiralCache: (size: CGFloat, value: [[CGPoint]])?
    private let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Diction/hub", isDirectory: true)
    private var dictationsURL: URL { dir.appendingPathComponent("dictations.jsonl") }

    private init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        if let lines = try? String(contentsOf: dictationsURL, encoding: .utf8) {
            dictations = lines.split(separator: "\n")
                .compactMap { try? decoder.decode(DictationRecord.self, from: Data($0.utf8)) }
                .reversed()
        }
        totalWords = dictations.reduce(0) { $0 + $1.words }
        snippets = load("snippets.json") ?? []
    }

    /// Called right before a dictation is pasted: expands snippets, applies the style, logs it,
    /// and returns the text to paste.
    func finish(_ cleaned: String, raw: String) -> String {
        let text = StyleFormatter.apply(SnippetExpander.expand(cleaned, snippets: snippets), style: .current)
        let record = DictationRecord(date: Date(), text: text, raw: raw)
        dictations.insert(record, at: 0)
        totalWords += record.words
        if let data = try? JSONEncoder().encode(record), let handle = try? FileHandle(forWritingTo: dictationsURL) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        } else if let data = try? JSONEncoder().encode(record) {
            try? (data + Data("\n".utf8)).write(to: dictationsURL)
        }
        return text
    }

    func deleteDictation(_ record: DictationRecord) {
        dictations.removeAll { $0.id == record.id }
        totalWords -= record.words
        let encoder = JSONEncoder()
        let lines = dictations.reversed().compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: dictationsURL, atomically: true, encoding: .utf8)
    }

    func spiral(size: CGFloat) -> [[CGPoint]] {
        if let cache = spiralCache, cache.size == size { return cache.value }
        let value = Spiral.segments(dictations, size: size)
        spiralCache = (size, value)
        return value
    }

    // MARK: storage

    private func load<T: Decodable>(_ name: String) -> T? {
        (try? Data(contentsOf: dir.appendingPathComponent(name))).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        try? JSONEncoder().encode(value).write(to: dir.appendingPathComponent(name), options: .atomic)
    }
}
