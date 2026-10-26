import Foundation
import Security

final class LocalLLMCleanupBackend: CleanupBackend {
    private let cleanupManager: TextCleaningManaging

    init(cleanupManager: TextCleaningManaging) {
        self.cleanupManager = cleanupManager
    }

    func clean(text: String, prompt: String, modelKind: LocalCleanupModelKind?) async throws -> String {
        try await cleanupManager.clean(text: text, prompt: prompt, modelKind: modelKind)
    }
}

/// Cleans dictation with Claude Haiku, falling back to the local model when Haiku can't be used.
/// Needs two things, otherwise it behaves exactly like the local backend:
/// - the API key in the macOS Keychain, service "anthropic-api-key"
/// - ~/Library/Application Support/Diction/haiku_prompt.txt (rules + examples of your own dictations,
///   written by make_haiku_prompt.py)
/// Only the transcript and the on-screen context leave the Mac; audio never does.
final class AnthropicCleanupBackend: CleanupBackend {
    private let fallback: CleanupBackend
    // shared, so warmUp() and the real cleanup reuse the same open connection
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5  // ponytail: fixed 5 s, past that the local model is the better bet
        return URLSession(configuration: config)
    }()
    // read once per launch: every Keychain read can show a permission prompt for an ad-hoc signed build
    private static var storedKey: String? = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        ?? readKeychain(service: "anthropic-api-key")
    private static let keyLock = NSLock()  // Settings can replace the key while a cleanup reads it
    private static var apiKey: String? { localOnly ? nil : keyLock.withLock { storedKey } }  // nil: the local model cleans up
    static var hasAPIKey: Bool { keyLock.withLock { storedKey } != nil }
    @MainActor private static var lastWarmUp = Date.distantPast
    // the request prefetch() sent at a pause in speech, keyed by its exact content
    private static let earlyLock = NSLock()
    private static var early: (key: String, answer: Task<String, Error>)?

    init(fallback: CleanupBackend) {
        self.fallback = fallback
        Task { @MainActor in Self.warmUp() }  // so the first dictation after launch is fast too
    }

    /// A cold first request took 5.6 s instead of 1.2 s: new connection, prompt cache not yet written,
    /// JSON output format not yet prepared by the API. A tiny request with the same prompt warms all three.
    /// Called at launch and whenever recording starts, so it's ready by the time you release the key.
    /// At most every 4 min: the prompt cache lives 5 min, so that keeps it warm while you dictate.
    @MainActor static func warmUp() {
        guard let key = apiKey, let system = try? String(contentsOf: promptURL, encoding: .utf8) else { return }
        guard Date().timeIntervalSince(lastWarmUp) > 240 else {
            // The prompt cache is still warm. Only keep the connection open (a free request), so the cleanup
            // at release doesn't pay the 60-180 ms it takes to set up a new encrypted connection.
            var ping = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
            ping.setValue(key, forHTTPHeaderField: "x-api-key")
            ping.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            Task { _ = try? await session.data(for: ping) }
            return
        }
        lastWarmUp = Date()
        Task {
            let start = Date()
            let input = "<USER-INPUT>\nok\n</USER-INPUT>"
            _ = try? await callHaiku(key: key, system: system, user: input, input: input)
            log("warm-up", start)
        }
    }

    static var promptURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Diction/haiku_prompt.txt")
    }

    func clean(text: String, prompt: String, modelKind: LocalCleanupModelKind?) async throws -> String {
        let start = Date()
        let spoken = Self.spoken(text)
        // Haiku made 1-3-word dictations slightly worse in the cleanup benchmark (7.4 % vs 6.2 % characters
        // wrong without it) and costs ~1.4 s, so they're pasted as transcribed.
        if Self.isShort(spoken) {
            Self.log("skipped: 3 words or fewer", start)
            return spoken
        }
        guard let key = Self.apiKey, let system = try? String(contentsOf: Self.promptURL, encoding: .utf8) else {
            Self.log(Self.apiKey == nil ? "local: no API key (Keychain denied or empty)" : "local: haiku_prompt.txt missing", start)
            return try await fallback.clean(text: text, prompt: prompt, modelKind: modelKind)
        }
        let user = Self.userMessage(text: text, prompt: prompt)
        if let early = Self.takeEarly(key: system + user) {
            do {
                let cleaned = try await early.value
                Self.log("haiku ok (asked at a pause)", start)
                return cleaned
            } catch let error as CleanupBackendError {
                Self.log("haiku unusable output, raw transcript pasted", start)
                throw error
            } catch {
                // the early request failed (offline, timeout): ask again below, with the local fallback
            }
        }
        do {
            let cleaned = try await Self.callHaiku(key: key, system: system, user: user, input: text)
            Self.log("haiku ok", start)
            return cleaned
        } catch let error as CleanupBackendError {
            Self.log("haiku unusable output, raw transcript pasted", start)
            throw error  // Haiku answered but the text is unusable: TextCleaner pastes the raw transcript
        } catch {
            Self.log("local: haiku failed (\(error.localizedDescription))", start)
            return try await fallback.clean(text: text, prompt: prompt, modelKind: modelKind)  // offline, timeout, HTTP error
        }
    }

    /// Sends the Haiku request for this text now, at a pause in speech, before the key is released.
    /// clean() with the same text and prompt then waits for this answer instead of asking again; any other
    /// text or prompt makes a different request, so a stale answer can't be pasted. No local fallback here:
    /// if this request fails, clean() asks again.
    func prefetch(text: String, prompt: String) {
        guard !Self.isShort(Self.spoken(text)), let key = Self.apiKey,
              let system = try? String(contentsOf: Self.promptURL, encoding: .utf8) else { return }
        let user = Self.userMessage(text: text, prompt: prompt)
        let answer = Task { try await Self.callHaiku(key: key, system: system, user: user, input: text) }
        Self.earlyLock.withLock {
            Self.early?.answer.cancel()  // a newer pause replaces it
            Self.early = (system + user, answer)
        }
    }

    private static func takeEarly(key: String) -> Task<String, Error>? {
        earlyLock.withLock {
            guard let early, early.key == key else { return nil }
            Self.early = nil
            return early.answer
        }
    }

    /// The local model's prompt = its default instructions + dictionary hints + window OCR.
    /// Haiku gets its own instructions, so pass on only the context part.
    private static func userMessage(text: String, prompt: String) -> String {
        let context = prompt.hasPrefix(TextCleaner.defaultPrompt)
            ? String(prompt.dropFirst(TextCleaner.defaultPrompt.count)) : prompt
        // Style → Auto cleanup → Medium. After the cached system prompt, so the prompt cache still hits.
        let medium = UserDefaults.standard.bool(forKey: "cleanupMedium")
            ? "\n\nCleanup level: medium. Also edit for clarity and conciseness: drop repetition and tighten wordy sentences, keep the meaning and the language."
            : ""
        return "\(context)\(medium)\n\n\(text)"
    }

    /// The dictation without the <USER-INPUT> tags TextCleaner wraps it in.
    private static func spoken(_ input: String) -> String {
        input.replacingOccurrences(of: "<USER-INPUT>", with: "")
            .replacingOccurrences(of: "</USER-INPUT>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isShort(_ spoken: String) -> Bool {
        spoken.split(whereSeparator: \.isWhitespace).count <= 3
    }

    /// One line per dictation in Diction/haiku.log: which path ran and how long it took. Never the text.
    private static func log(_ message: String, _ start: Date) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(Int(Date().timeIntervalSince(start) * 1000)) ms \(message)\n"
        let url = promptURL.deletingLastPathComponent().appendingPathComponent("haiku.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func callHaiku(key: String, system: String, user: String, input: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": "claude-haiku-5-5",
            "max_tokens": input.count / 2 + 256,
            // a light rewrite, not a reasoning task: no thinking, low effort keeps it fast
            "thinking": ["type": "disabled"],
            "output_config": [
                "effort": "low",
                // forcing a JSON field leaves no room to answer or comment on the dictation
                "format": ["type": "json_schema", "schema": [
                    "type": "object", "properties": ["text": ["type": "string"]],
                    "required": ["text"], "additionalProperties": false,
                ]],
            ],
            // the rules + examples never change, so they're cached after the first call
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": user]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let blocks = json?["content"] as? [[String: Any]] ?? []
        let raw = blocks.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
        let cleaned = ((try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any])?["text"] as? String ?? ""

        // same guard as the benchmark: empty, or far longer/shorter than what was said = something went wrong
        let ratio = Double(cleaned.count) / Double(max(spoken(input).count, 1))
        let shortest = UserDefaults.standard.bool(forKey: "cleanupMedium") ? 0.45 : 0.7  // medium cleanup is meant to shorten
        guard !cleaned.isEmpty, (shortest...1.3).contains(ratio) else { throw CleanupBackendError.unusableOutput(rawOutput: raw) }
        return cleaned
    }

    /// Stores the key under the service the cleanup reads (replacing an older one) and uses it from the next dictation on.
    static func saveAPIKey(_ key: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "anthropic-api-key"]
        let data = Data(key.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecAttrAccount as String] = "Diction"
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return false }
        keyLock.withLock { storedKey = key }
        return true
    }

    private static func readKeychain(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
