import Foundation
import Combine

enum DebugLogCategory: String, Codable {
    case hotkey = "Hotkey"
    case ocr = "OCR"
    case cleanup = "Cleanup"
    case model = "Model"
    case performance = "Performance"
}

struct DebugLogEntry: Identifiable, Equatable, Codable {
    let id: UUID
    let timestamp: Date
    let category: DebugLogCategory
    let message: String

    init(
        id: UUID = UUID(),
        timestamp: Date,
        category: DebugLogCategory,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.message = message
    }
}

final class DebugLogStore: ObservableObject {
    @Published private(set) var entries: [DebugLogEntry] = []

    private let maxEntries: Int
    private let storageURL: URL
    private let formatter: DateFormatter
    private var liveViewerCount = 0

    init(maxEntries: Int = 250, storageURL: URL? = nil) {
        self.maxEntries = maxEntries
        self.storageURL = storageURL ?? Self.defaultStorageURL
        self.formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        entries = loadEntries()
        trimToCapacity()
    }

    var formattedText: String {
        entries.map { entry in
            "[\(formatter.string(from: entry.timestamp))] [\(entry.category.rawValue)] \(entry.message)"
        }
        .joined(separator: "\n\n")
    }

    func record(category: DebugLogCategory, message: String) {
        entries.append(
            DebugLogEntry(
                timestamp: Date(),
                category: category,
                message: message
            )
        )

        trimToCapacity()
        persistEntries()
    }

    func beginLiveViewing() {
        liveViewerCount += 1
    }

    func endLiveViewing() {
        liveViewerCount = max(0, liveViewerCount - 1)
    }

    func recordSensitive(category: DebugLogCategory, message: String) {
        guard liveViewerCount > 0 else {
            return
        }

        record(category: category, message: message)
    }

    func clear() {
        entries.removeAll()
        persistEntries()
    }

    private func trimToCapacity() {
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    private func loadEntries() -> [DebugLogEntry] {
        guard let data = try? Data(contentsOf: storageURL) else {
            return []
        }

        return (try? JSONDecoder().decode([DebugLogEntry].self, from: data)) ?? []
    }

    private func persistEntries() {
        let directory = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else {
            return
        }
        try? data.write(to: storageURL, options: .atomic)
    }

    static var defaultStorageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Diction", isDirectory: true)
            .appendingPathComponent("debug-log.json")
    }
}
