import XCTest
@testable import Diction

@MainActor
final class DebugLogStoreTests: XCTestCase {
    private func makeStore(maxEntries: Int = 250) -> DebugLogStore {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("debug-log.json")
        return DebugLogStore(maxEntries: maxEntries, storageURL: fileURL)
    }

    func testStorePersistsEntriesAcrossInstances() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("debug-log.json")

        do {
            let firstStore = DebugLogStore(maxEntries: 10, storageURL: fileURL)
            firstStore.record(category: .performance, message: "session complete")
        }

        let secondStore = DebugLogStore(maxEntries: 10, storageURL: fileURL)

        XCTAssertEqual(secondStore.entries.map(\.message), ["session complete"])
    }

    func testStoreDropsOldestEntriesWhenCapacityIsExceeded() {
        let store = makeStore(maxEntries: 2)

        store.record(category: .hotkey, message: "first")
        store.record(category: .ocr, message: "second")
        store.record(category: .cleanup, message: "third")

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries.map(\.message), ["second", "third"])
    }

    func testClearRemovesFormattedLogOutput() {
        let store = makeStore(maxEntries: 2)

        store.record(category: .model, message: "loaded")
        store.clear()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.formattedText, "")
    }

    func testSensitiveEntriesAreIgnoredWhenNoDebugViewerIsOpen() {
        let store = makeStore()

        store.recordSensitive(category: .cleanup, message: "full prompt")

        XCTAssertTrue(store.entries.isEmpty)
    }

    func testSensitiveEntriesAreRecordedOnlyWhileDebugViewerIsOpen() {
        let store = makeStore()

        store.beginLiveViewing()
        store.recordSensitive(category: .cleanup, message: "full prompt")
        store.endLiveViewing()
        store.recordSensitive(category: .cleanup, message: "full output")

        XCTAssertEqual(store.entries.map(\.message), ["full prompt"])
    }
}
