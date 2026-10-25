import XCTest
import SwiftUI
import Combine
@testable import Diction

private final class FakeHotkeyMonitor: HotkeyMonitoring {
    var onRecordingStart: (() -> Void)?
    var onRecordingStop: (() -> Void)?
    var onPushToTalkStart: (() -> Void)?
    var onPushToTalkStop: (() -> Void)?
    var onToggleToTalkStart: (() -> Void)?
    var onToggleToTalkStop: (() -> Void)?
    var onRecordingRestart: (() -> Void)?
    var onRecordingCancel: (() -> Void)?

    var updatedBindings: [ChordAction: KeyChord] = [:]
    var startResult = true
    var startCallCount = 0
    var suspendedStates: [Bool] = []

    func start() -> Bool {
        startCallCount += 1
        return startResult
    }

    func stop() {}

    func updateBindings(_ bindings: [ChordAction: KeyChord]) {
        updatedBindings = bindings
    }

    func setSuspended(_ suspended: Bool) {
        suspendedStates.append(suspended)
    }

    func cancelActiveChord() {}
}

private final class FakeAppRelauncher: AppRelaunching {
    var relaunchCallCount = 0
    var error: Error?

    func relaunch() throws {
        relaunchCallCount += 1
        if let error {
            throw error
        }
    }
}

private final class FakeRecordingTranscriptionSession: RecordingTranscriptionSession {
    private(set) var appendedChunks: [[Float]] = []
    private(set) var finishCallCount = 0
    private(set) var cancelCallCount = 0
    var finalTranscript: String?
    let allowsBatchFallback: Bool
    let supportsConcurrentFinalization = false

    init(finalTranscript: String?, allowsBatchFallback: Bool = false) {
        self.finalTranscript = finalTranscript
        self.allowsBatchFallback = allowsBatchFallback
    }

    func appendAudioChunk(_ samples: [Float]) {
        appendedChunks.append(samples)
    }

    func finishTranscription() async -> String? {
        finishCallCount += 1
        return finalTranscript
    }

    func cancel() {
        cancelCallCount += 1
    }
}

@MainActor
private final class AppStateSpeechAnalyzerStub: SpeechAnalyzerTranscribing {
    func transcribe(audioBuffer: [Float]) async throws -> String? {
        nil
    }
}

@MainActor
private final class MeetingSpeechAnalyzerStub: SpeechAnalyzerTranscribing {
    func transcribe(audioBuffer: [Float]) async throws -> String? {
        "late audio"
    }
}

private final class FakeMeetingAudioCapture: MeetingAudioCapturing {
    var onAudioChunk: ((TaggedAudioChunk) -> Void)?
    var onStop: (() -> Void)?

    func start() async throws {}

    func stop() async -> (micBuffer: [Float], systemBuffer: [Float]) {
        onStop?()
        return ([], [])
    }

    var elapsed: TimeInterval { 0 }
}

@MainActor
private final class AsyncTestGate {
    private var isReleased = false

    func wait() async {
        for _ in 0..<200 {
            guard !isReleased else { return }
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                return
            }
        }
    }

    func release() {
        isReleased = true
    }
}

@MainActor
final class DictionTests: XCTestCase {
    private func makeDebugLogStore() -> DebugLogStore {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("debug-log.json")
        return DebugLogStore(storageURL: fileURL)
    }

    private func waitForCondition(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: () -> Bool
    ) async {
        let pollIntervalNanoseconds: UInt64 = 10_000_000
        var elapsedNanoseconds: UInt64 = 0
        while !condition() && elapsedNanoseconds < timeoutNanoseconds {
            do {
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            } catch {
                return
            }
            elapsedNanoseconds += pollIntervalNanoseconds
        }

        if !condition() {
            XCTFail("Timed out waiting for test condition")
        }
    }

    override func tearDown() {
        PermissionChecker.current = PermissionChecker.defaultClient
        super.tearDown()
    }

    func testAppStateInitialStatus() {
        // AppState is @MainActor so we test basic enum
        XCTAssertEqual(AppStatus.ready.rawValue, "Ready")
        XCTAssertEqual(AppStatus.recording.rawValue, "Recording...")
        XCTAssertEqual(AppStatus.transcribing.rawValue, "Transcribing...")
        XCTAssertEqual(AppStatus.error.rawValue, "Error")
    }

    func testAppStatePassesPreferredLanguageWhenLoadingSpeechAnalyzer() async throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        var requestedLanguages: [String?] = []
        let manager = ModelManager(
            modelName: SpeechModelCatalog.speechAnalyzer.id,
            speechAnalyzerBackendFactory: { language in
                requestedLanguages.append(language)
                return AppStateSpeechAnalyzerStub()
            }
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let previousLanguage = UserDefaults.standard.object(forKey: "preferredLanguage")
        defer {
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: "preferredLanguage")
            } else {
                UserDefaults.standard.removeObject(forKey: "preferredLanguage")
            }
        }
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            modelManager: manager
        )

        appState.preferredLanguage = "es"
        await appState.loadSpeechModel(name: SpeechModelCatalog.speechAnalyzer.id)
        appState.preferredLanguage = "auto"
        await appState.loadSpeechModel(name: SpeechModelCatalog.speechAnalyzer.id)

        XCTAssertEqual(requestedLanguages.count, 2)
        XCTAssertEqual(requestedLanguages[0], "es")
        XCTAssertNil(requestedLanguages[1])
    }

    func testAppStateRepreparesForLanguageChangesOnlyWhenSpeechAnalyzerIsSelected() async throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        var requestedLanguages: [String?] = []
        let manager = ModelManager(
            modelName: SpeechModelCatalog.speechAnalyzer.id,
            speechAnalyzerBackendFactory: { language in
                requestedLanguages.append(language)
                return AppStateSpeechAnalyzerStub()
            }
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let previousLanguage = UserDefaults.standard.object(forKey: "preferredLanguage")
        let previousModel = UserDefaults.standard.object(forKey: "speechModel")
        defer {
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: "preferredLanguage")
            } else {
                UserDefaults.standard.removeObject(forKey: "preferredLanguage")
            }
            if let previousModel {
                UserDefaults.standard.set(previousModel, forKey: "speechModel")
            } else {
                UserDefaults.standard.removeObject(forKey: "speechModel")
            }
        }
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            modelManager: manager
        )
        appState.preferredLanguage = "fr"

        appState.speechModel = SpeechModelCatalog.whisperSmallEnglish.id
        await appState.reloadSpeechAnalyzerForPreferredLanguageIfNeeded()
        XCTAssertTrue(requestedLanguages.isEmpty)

        appState.speechModel = SpeechModelCatalog.speechAnalyzer.id
        await appState.reloadSpeechAnalyzerForPreferredLanguageIfNeeded()
        XCTAssertEqual(requestedLanguages.count, 1)
        XCTAssertEqual(requestedLanguages[0], "fr")
    }

    func testAppStateRepreparesSpeechAnalyzerAfterAnInFlightLoadFinishes() async throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        var requestedLanguages: [String?] = []
        let initialLoadGate = AsyncTestGate()
        let manager = ModelManager(
            modelName: SpeechModelCatalog.speechAnalyzer.id,
            speechAnalyzerBackendFactory: { language in
                requestedLanguages.append(language)
                if requestedLanguages.count == 1 {
                    await initialLoadGate.wait()
                }
                return AppStateSpeechAnalyzerStub()
            }
        )
        defer { initialLoadGate.release() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let previousLanguage = UserDefaults.standard.object(forKey: "preferredLanguage")
        let previousModel = UserDefaults.standard.object(forKey: "speechModel")
        defer {
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: "preferredLanguage")
            } else {
                UserDefaults.standard.removeObject(forKey: "preferredLanguage")
            }
            if let previousModel {
                UserDefaults.standard.set(previousModel, forKey: "speechModel")
            } else {
                UserDefaults.standard.removeObject(forKey: "speechModel")
            }
        }
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            modelManager: manager
        )
        appState.preferredLanguage = "en"
        appState.speechModel = SpeechModelCatalog.speechAnalyzer.id

        let initialLoad = Task { await appState.loadSpeechModel(name: SpeechModelCatalog.speechAnalyzer.id) }
        await waitForCondition { !requestedLanguages.isEmpty }

        appState.preferredLanguage = "fr"
        let reload = Task { await appState.reloadSpeechAnalyzerForPreferredLanguageIfNeeded() }
        await Task.yield()
        initialLoadGate.release()

        await initialLoad.value
        await reload.value

        XCTAssertEqual(requestedLanguages, ["en", "fr"])
    }

    func testAppStateWaitsForQueuedModelSelectionToFinish() async throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        let firstLoadGate = AsyncTestGate()
        var loadedNames: [String] = []
        let manager = ModelManager(
            modelName: SpeechModelCatalog.whisperSmallEnglish.id,
            modelLoadOverride: { descriptor in
                loadedNames.append(descriptor.name)
                if loadedNames.count == 1 {
                    await firstLoadGate.wait()
                }
            }
        )
        defer { firstLoadGate.release() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            modelManager: manager
        )
        appState.speechModel = SpeechModelCatalog.whisperSmallEnglish.id

        let initialLoad = Task { await appState.loadSpeechModel(name: SpeechModelCatalog.whisperSmallEnglish.id) }
        await waitForCondition { manager.state == .loading }

        appState.speechModel = SpeechModelCatalog.speechAnalyzer.id
        let queuedLoad = Task { await appState.loadSpeechModel(name: SpeechModelCatalog.speechAnalyzer.id) }
        for _ in 0..<20 {
            await Task.yield()
        }
        firstLoadGate.release()

        await queuedLoad.value
        XCTAssertEqual(manager.modelName, SpeechModelCatalog.speechAnalyzer.id)
        XCTAssertTrue(manager.isReady)
        XCTAssertEqual(appState.status, .ready)

        await initialLoad.value
    }

    func testMeetingStopDrainsAudioDeliveredWhileCaptureStops() async throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }

        let manager = ModelManager(
            modelName: SpeechModelCatalog.speechAnalyzer.id,
            speechAnalyzerBackendFactory: { _ in MeetingSpeechAnalyzerStub() }
        )
        await manager.loadModel(name: SpeechModelCatalog.speechAnalyzer.id)
        let capture = FakeMeetingAudioCapture()
        let session = MeetingSession(
            meetingName: "Late audio",
            transcriber: SpeechTranscriber(modelManager: manager),
            saveDirectory: FileManager.default.temporaryDirectory,
            capture: capture
        )
        capture.onStop = { [weak capture] in
            capture?.onAudioChunk?(
                TaggedAudioChunk(source: .mic, samples: [0.25], timestamp: 0)
            )
        }

        try await session.start()
        await session.stop()

        await waitForCondition { session.transcript.segments.count == 1 }
        XCTAssertEqual(session.transcript.segments.first?.text, "late audio")
    }

    func testAppStateGatesRecordingWhileSpeechAnalyzerReloads() async throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        var factoryCallCount = 0
        let reloadGate = AsyncTestGate()
        let manager = ModelManager(
            modelName: SpeechModelCatalog.speechAnalyzer.id,
            speechAnalyzerBackendFactory: { _ in
                factoryCallCount += 1
                if factoryCallCount == 2 {
                    await reloadGate.wait()
                }
                return AppStateSpeechAnalyzerStub()
            }
        )
        defer { reloadGate.release() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            modelManager: manager
        )
        appState.speechModel = SpeechModelCatalog.speechAnalyzer.id
        appState.preferredLanguage = "en"
        await appState.loadSpeechModel(name: SpeechModelCatalog.speechAnalyzer.id)
        appState.status = .ready

        appState.preferredLanguage = "fr"
        let reload = Task { await appState.reloadSpeechAnalyzerForPreferredLanguageIfNeeded() }
        await waitForCondition { factoryCallCount >= 2 }

        XCTAssertEqual(appState.status, .loading)

        reloadGate.release()
        await reload.value
        XCTAssertEqual(appState.status, .ready)
    }

    func testAppStatePreservesUnrelatedErrorWhileReloadingSpeechAnalyzer() async throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        let manager = ModelManager(
            modelName: SpeechModelCatalog.speechAnalyzer.id,
            speechAnalyzerBackendFactory: { _ in AppStateSpeechAnalyzerStub() }
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            modelManager: manager
        )
        appState.speechModel = SpeechModelCatalog.speechAnalyzer.id
        appState.preferredLanguage = "en"
        await appState.loadSpeechModel(name: SpeechModelCatalog.speechAnalyzer.id)
        appState.status = .error
        appState.errorMessage = "Accessibility access required"
        appState.preferredLanguage = "fr"

        await appState.reloadSpeechAnalyzerForPreferredLanguageIfNeeded()

        XCTAssertEqual(appState.status, .error)
        XCTAssertEqual(appState.errorMessage, "Accessibility access required")
    }

    func testAppStateDoesNotStartRecordingWhenModelManagerIsNotReady() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        let appState = AppState(
            hotkeyMonitor: monitor,
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            modelManager: ModelManager(modelName: SpeechModelCatalog.speechAnalyzer.id)
        )
        appState.status = .ready

        await appState.startHotkeyMonitor()
        monitor.onRecordingStart?()
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertEqual(appState.status, .ready)
        XCTAssertFalse(appState.isRecording)
    }

    func testAppStateOverlappingSpeechAnalyzerReloadsKeepRecordingGatedUntilNewestLoadFinishes() async throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        var requestedLanguages: [String?] = []
        let firstGate = AsyncTestGate()
        let secondGate = AsyncTestGate()
        let manager = ModelManager(
            modelName: SpeechModelCatalog.speechAnalyzer.id,
            speechAnalyzerBackendFactory: { language in
                requestedLanguages.append(language)
                switch requestedLanguages.count {
                case 2:
                    await firstGate.wait()
                case 3:
                    await secondGate.wait()
                default:
                    break
                }
                return AppStateSpeechAnalyzerStub()
            }
        )
        defer {
            firstGate.release()
            secondGate.release()
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        let appState = AppState(
            hotkeyMonitor: monitor,
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            modelManager: manager
        )
        appState.speechModel = SpeechModelCatalog.speechAnalyzer.id
        appState.preferredLanguage = "en"
        await appState.loadSpeechModel(name: SpeechModelCatalog.speechAnalyzer.id)
        appState.status = .ready

        appState.preferredLanguage = "fr"
        let firstReload = Task { await appState.reloadSpeechAnalyzerForPreferredLanguageIfNeeded() }
        await waitForCondition { requestedLanguages.count >= 2 }

        appState.preferredLanguage = "de"
        let secondReload = Task { await appState.reloadSpeechAnalyzerForPreferredLanguageIfNeeded() }

        firstGate.release()
        await waitForCondition { requestedLanguages.count >= 3 }

        XCTAssertEqual(requestedLanguages, ["en", "fr", "de"])
        XCTAssertEqual(appState.status, .loading)

        await appState.startHotkeyMonitor()
        appState.status = .loading
        monitor.onRecordingStart?()
        await Task.yield()
        XCTAssertEqual(appState.status, .loading)
        XCTAssertFalse(appState.isRecording)

        secondGate.release()
        await firstReload.value
        await secondReload.value
        XCTAssertEqual(appState.status, .ready)
    }

    func testAppStateRestoresReadyWhenNewestSpeechAnalyzerReloadIsCancelled() async throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        var requestedLanguages: [String?] = []
        let firstGate = AsyncTestGate()
        let manager = ModelManager(
            modelName: SpeechModelCatalog.speechAnalyzer.id,
            speechAnalyzerBackendFactory: { language in
                requestedLanguages.append(language)
                if requestedLanguages.count == 2 {
                    await firstGate.wait()
                }
                return AppStateSpeechAnalyzerStub()
            }
        )
        defer { firstGate.release() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            modelManager: manager
        )
        appState.speechModel = SpeechModelCatalog.speechAnalyzer.id
        appState.preferredLanguage = "en"
        await appState.loadSpeechModel(name: SpeechModelCatalog.speechAnalyzer.id)
        appState.status = .ready

        appState.preferredLanguage = "fr"
        let firstReload = Task { await appState.reloadSpeechAnalyzerForPreferredLanguageIfNeeded() }
        await waitForCondition { requestedLanguages.count >= 2 }

        appState.preferredLanguage = "de"
        let newestReload = Task { await appState.reloadSpeechAnalyzerForPreferredLanguageIfNeeded() }
        await waitForCondition { appState.status == .loading }
        newestReload.cancel()

        firstGate.release()
        await firstReload.value
        await newestReload.value

        XCTAssertEqual(requestedLanguages, ["en", "fr"])
        XCTAssertEqual(appState.status, .ready)
    }

    func testAppStateWaitsForActiveRecordingBeforeReloadingSpeechAnalyzer() async throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        var factoryCallCount = 0
        let manager = ModelManager(
            modelName: SpeechModelCatalog.speechAnalyzer.id,
            speechAnalyzerBackendFactory: { _ in
                factoryCallCount += 1
                return AppStateSpeechAnalyzerStub()
            }
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            modelManager: manager
        )
        appState.speechModel = SpeechModelCatalog.speechAnalyzer.id
        appState.preferredLanguage = "en"
        await appState.loadSpeechModel(name: SpeechModelCatalog.speechAnalyzer.id)
        appState.status = .recording
        appState.isRecording = true
        appState.preferredLanguage = "fr"

        let reload = Task { await appState.reloadSpeechAnalyzerForPreferredLanguageIfNeeded() }
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertEqual(factoryCallCount, 1)
        XCTAssertEqual(appState.status, .recording)

        appState.isRecording = false
        appState.status = .ready
        await reload.value

        XCTAssertEqual(factoryCallCount, 2)
        XCTAssertEqual(appState.status, .ready)
    }

    func testAppStateWaitsForActiveMeetingSessionBeforeReloadingSpeechAnalyzer() async throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        var factoryCallCount = 0
        let reloadGate = AsyncTestGate()
        let manager = ModelManager(
            modelName: SpeechModelCatalog.speechAnalyzer.id,
            speechAnalyzerBackendFactory: { _ in
                factoryCallCount += 1
                if factoryCallCount == 2 {
                    await reloadGate.wait()
                }
                return AppStateSpeechAnalyzerStub()
            }
        )
        defer { reloadGate.release() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            modelManager: manager
        )
        appState.speechModel = SpeechModelCatalog.speechAnalyzer.id
        appState.preferredLanguage = "en"
        await appState.loadSpeechModel(name: SpeechModelCatalog.speechAnalyzer.id)
        appState.status = .ready

        let meetingSession = MeetingSession(
            meetingName: "Test meeting",
            transcriber: appState.transcriber,
            saveDirectory: FileManager.default.temporaryDirectory
        )
        meetingSession.isActive = true
        appState.activeMeetingSession = meetingSession
        appState.preferredLanguage = "fr"

        let reload = Task { await appState.reloadSpeechAnalyzerForPreferredLanguageIfNeeded() }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(factoryCallCount, 1)
        XCTAssertEqual(appState.status, .ready)

        meetingSession.isActive = false
        await waitForCondition { factoryCallCount >= 2 }
        XCTAssertEqual(appState.status, .loading)

        reloadGate.release()
        await reload.value
        XCTAssertEqual(appState.status, .ready)
    }

    func testAppStateWaitsForMeetingSessionStartupBeforeReloadingSpeechAnalyzer() async throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        var factoryCallCount = 0
        let reloadGate = AsyncTestGate()
        let manager = ModelManager(
            modelName: SpeechModelCatalog.speechAnalyzer.id,
            speechAnalyzerBackendFactory: { _ in
                factoryCallCount += 1
                if factoryCallCount == 2 {
                    await reloadGate.wait()
                }
                return AppStateSpeechAnalyzerStub()
            }
        )
        defer { reloadGate.release() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            modelManager: manager
        )
        appState.speechModel = SpeechModelCatalog.speechAnalyzer.id
        appState.preferredLanguage = "en"
        await appState.loadSpeechModel(name: SpeechModelCatalog.speechAnalyzer.id)
        appState.status = .ready

        let startGate = AsyncTestGate()
        let meetingSession = MeetingSession(
            meetingName: "Starting meeting",
            transcriber: appState.transcriber,
            saveDirectory: FileManager.default.temporaryDirectory,
            captureStartOverride: {
                await startGate.wait()
            }
        )
        appState.activeMeetingSession = meetingSession
        let startTask = Task {
            try? await meetingSession.start()
        }
        await waitForCondition { meetingSession.isStarting }
        appState.preferredLanguage = "fr"

        let reload = Task { await appState.reloadSpeechAnalyzerForPreferredLanguageIfNeeded() }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(factoryCallCount, 1)
        XCTAssertEqual(appState.status, .ready)

        startGate.release()
        await startTask.value
        appState.activeMeetingSession = nil
        await waitForCondition { factoryCallCount >= 2 }
        XCTAssertEqual(appState.status, .loading)

        reloadGate.release()
        await reload.value
        XCTAssertEqual(appState.status, .ready)
    }

    func testMeetingSessionStopWaitsForStartupToFinish() async throws {
        let startGate = AsyncTestGate()
        let session = MeetingSession(
            meetingName: "Starting meeting",
            transcriber: SpeechTranscriber(modelManager: ModelManager()),
            saveDirectory: FileManager.default.temporaryDirectory,
            captureStartOverride: {
                await startGate.wait()
            }
        )

        let startTask = Task {
            try? await session.start()
        }
        await waitForCondition { session.isStarting }

        let stopTask = Task { await session.stop() }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertTrue(session.isStarting)

        startGate.release()
        await startTask.value
        await stopTask.value

        XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.isStarting)
        XCTAssertFalse(session.isDraining)
    }

    func testMeetingSessionStopBeforeStartupCancelsNextStart() async throws {
        var captureStartCallCount = 0
        let session = MeetingSession(
            meetingName: "Cancelled meeting",
            transcriber: SpeechTranscriber(modelManager: ModelManager()),
            saveDirectory: FileManager.default.temporaryDirectory,
            captureStartOverride: {
                captureStartCallCount += 1
            }
        )

        await session.stop()
        try await session.start()

        XCTAssertEqual(captureStartCallCount, 0)
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.isStarting)
        XCTAssertFalse(session.isDraining)
    }

    func testMeetingSessionStopCleansUpAfterStartupFailure() async throws {
        struct StartupFailure: Error {}
        let session = MeetingSession(
            meetingName: "Failed meeting",
            transcriber: SpeechTranscriber(modelManager: ModelManager()),
            saveDirectory: FileManager.default.temporaryDirectory,
            captureStartOverride: {
                throw StartupFailure()
            }
        )

        do {
            try await session.start()
            XCTFail("Expected meeting startup to fail")
        } catch is StartupFailure {
            // Expected failure from the injected capture startup.
        }

        await session.stop()

        XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.isStarting)
        XCTAssertFalse(session.isDraining)
        XCTAssertNotNil(session.fileURL)
        XCTAssertNotNil(session.transcript.endDate)
    }

    func testAppStateCancellingSpeechAnalyzerReloadWhileRecordingDoesNotLoadOrChangeStatus() async throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        var factoryCallCount = 0
        let manager = ModelManager(
            modelName: SpeechModelCatalog.speechAnalyzer.id,
            speechAnalyzerBackendFactory: { _ in
                factoryCallCount += 1
                return AppStateSpeechAnalyzerStub()
            }
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            modelManager: manager
        )
        appState.speechModel = SpeechModelCatalog.speechAnalyzer.id
        appState.preferredLanguage = "en"
        await appState.loadSpeechModel(name: SpeechModelCatalog.speechAnalyzer.id)
        appState.status = .recording
        appState.isRecording = true
        appState.preferredLanguage = "fr"

        let reload = Task { await appState.reloadSpeechAnalyzerForPreferredLanguageIfNeeded() }
        for _ in 0..<100 {
            await Task.yield()
        }
        reload.cancel()
        await reload.value

        XCTAssertEqual(factoryCallCount, 1)
        XCTAssertEqual(appState.status, .recording)
    }

    func testEmptyTranscriptionDispositionCancelsSubThresholdRecordings() {
        XCTAssertEqual(
            AppState.emptyTranscriptionDisposition(forAudioSampleCount: 7_999),
            .cancel
        )
    }

    func testEmptyTranscriptionDispositionShowsNoSoundDetectedAtThresholdAndAbove() {
        XCTAssertEqual(
            AppState.emptyTranscriptionDisposition(forAudioSampleCount: 8_000),
            .showNoSoundDetected
        )
        XCTAssertEqual(
            AppState.emptyTranscriptionDisposition(forAudioSampleCount: 9_600),
            .showNoSoundDetected
        )
    }

    func testNoSoundDetectedOverlayMessageUsesExpectedCopy() {
        XCTAssertEqual(OverlayMessage.noSoundDetected.primaryText, "No sound")
        XCTAssertEqual(
            OverlayMessage.noSoundDetected.secondaryText,
            "Check your microphone in Settings"
        )
    }

    func testClipboardFallbackOverlayMessageUsesExpectedCopy() {
        XCTAssertEqual(OverlayMessage.clipboardFallback(appName: "ChatGPT").primaryText, "Copied")
        XCTAssertEqual(OverlayMessage.clipboardFallback(appName: "ChatGPT").secondaryText, "Press ⌘V to paste")
    }

    func testOverlayHostingViewDoesNotManageWindowSizingConstraints() {
        let overlay = RecordingOverlayController()
        overlay.show(message: .recording)
        defer { overlay.dismiss() }

        let panel: NSPanel? = unwrapPrivateOptional(named: "panel", from: overlay)
        let hostingView: NSHostingView<OverlayPillView>? = unwrapPrivateOptional(
            named: "hostingView",
            from: overlay
        )

        XCTAssertNotNil(panel)
        XCTAssertNotNil(hostingView)
        XCTAssertEqual(hostingView?.sizingOptions, [])
        XCTAssertFalse(panel?.contentView is NSHostingView<OverlayPillView>)
    }

    private func unwrapPrivateOptional<T>(named name: String, from object: Any) -> T? {
        let mirror = Mirror(reflecting: object)
        guard let child = mirror.children.first(where: { $0.label == name }) else {
            return nil
        }

        let optionalMirror = Mirror(reflecting: child.value)
        guard optionalMirror.displayStyle == .optional else {
            return child.value as? T
        }

        return optionalMirror.children.first?.value as? T
    }

    func testAppStateLoadsDefaultShortcutBindingsIntoHotkeyMonitor() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        let appState = AppState(hotkeyMonitor: monitor, chordBindingStore: ChordBindingStore(defaults: defaults))

        await appState.startHotkeyMonitor()

        XCTAssertEqual(monitor.updatedBindings[.pushToTalk], AppState.defaultPushToTalkChord)
        XCTAssertEqual(monitor.updatedBindings[.toggleToTalk], AppState.defaultToggleToTalkChord)
    }

    func testAppStateWiresPushAndToggleCallbacksIntoHotkeyMonitor() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        let appState = AppState(hotkeyMonitor: monitor, chordBindingStore: ChordBindingStore(defaults: defaults))

        await appState.startHotkeyMonitor()

        XCTAssertNotNil(monitor.onPushToTalkStart)
        XCTAssertNotNil(monitor.onPushToTalkStop)
        XCTAssertNotNil(monitor.onToggleToTalkStart)
        XCTAssertNotNil(monitor.onToggleToTalkStop)
    }

    func testAppStateStartHotkeyMonitorSkipsRepeatedStartAfterSuccess() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        let appState = AppState(
            hotkeyMonitor: monitor,
            chordBindingStore: ChordBindingStore(defaults: defaults),
            inputMonitoringChecker: { true }
        )

        await appState.startHotkeyMonitor()
        await appState.startHotkeyMonitor()

        XCTAssertEqual(monitor.startCallCount, 1)
    }

    func testAppStateStartHotkeyMonitorPromptsForInputMonitoringButStillStartsWhenMonitorCanRun() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        var requestCount = 0
        let appState = AppState(
            hotkeyMonitor: monitor,
            chordBindingStore: ChordBindingStore(defaults: defaults),
            inputMonitoringChecker: { false },
            inputMonitoringPrompter: { requestCount += 1 }
        )

        await appState.startHotkeyMonitor()

        XCTAssertEqual(monitor.startCallCount, 1)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(appState.status, .ready)
        XCTAssertNil(appState.errorMessage)
    }

    func testAppStateUpdateShortcutRefreshesHotkeyMonitorBindings() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        let appState = AppState(hotkeyMonitor: monitor, chordBindingStore: ChordBindingStore(defaults: defaults))
        let newChord = try XCTUnwrap(KeyChord(keys: Set([
            PhysicalKey(keyCode: 54),
            PhysicalKey(keyCode: 61),
            PhysicalKey(keyCode: 53)
        ])))

        appState.updateShortcut(newChord, for: .pushToTalk)

        XCTAssertEqual(appState.pushToTalkChord, newChord)
        XCTAssertEqual(monitor.updatedBindings[.pushToTalk], newChord)
    }

    func testAppStateUpdateShortcutRejectsDuplicateBindings() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        let appState = AppState(hotkeyMonitor: monitor, chordBindingStore: ChordBindingStore(defaults: defaults))
        let originalToggleChord = appState.toggleToTalkChord

        appState.updateShortcut(AppState.defaultPushToTalkChord, for: .toggleToTalk)

        XCTAssertEqual(appState.toggleToTalkChord, originalToggleChord)
        XCTAssertEqual(monitor.updatedBindings[.toggleToTalk], originalToggleChord)
        XCTAssertEqual(appState.shortcutErrorMessage, "That shortcut is already in use.")
    }

    func testAppStateLoadsPersistedCleanupBackendSelection() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defaults.set("foundationModels", forKey: "cleanupBackend")

        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        XCTAssertEqual(appState.cleanupBackend, .localModels)
    }

    func testSpeechModelPresentationDoesNotExposeManagerLoadFailureInMenuErrorMessage() {
        let loadError = NSError(
            domain: NSURLErrorDomain,
            code: -1001,
            userInfo: [NSLocalizedDescriptionKey: "The request timed out."]
        )

        let next = AppState.nextSpeechModelPresentation(
            managerState: .error,
            managerError: loadError,
            currentStatus: .ready,
            currentErrorMessage: nil
        )

        XCTAssertEqual(next.status, .error)
        XCTAssertNil(next.errorMessage)
    }

    func testSpeechModelPresentationClearsStaleSpeechModelErrorAfterSuccessfulLoad() {
        let next = AppState.nextSpeechModelPresentation(
            managerState: .ready,
            managerError: nil,
            currentStatus: .error,
            currentErrorMessage: "Failed to load speech model: The request timed out."
        )

        XCTAssertEqual(next.status, .ready)
        XCTAssertNil(next.errorMessage)
    }

    func testSpeechModelPresentationPreservesUnrelatedErrorAfterSuccessfulLoad() {
        let next = AppState.nextSpeechModelPresentation(
            managerState: .ready,
            managerError: nil,
            currentStatus: .error,
            currentErrorMessage: "Accessibility access required — grant permission then click Retry"
        )

        XCTAssertEqual(next.status, .error)
        XCTAssertEqual(
            next.errorMessage,
            "Accessibility access required — grant permission then click Retry"
        )
    }

    func testAppStateUpdateCleanupBackendPersistsAndUpdatesTextCleaner() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        appState.updateCleanupBackend(.localModels)

        XCTAssertEqual(appState.cleanupBackend, .localModels)
        XCTAssertEqual(
            defaults.string(forKey: "cleanupBackend"),
            CleanupBackendOption.localModels.rawValue
        )
    }

    func testAppStatePersistsIgnoreOtherSpeakersPreference() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defaults.set(true, forKey: "ignoreOtherSpeakers")

        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        XCTAssertTrue(appState.ignoreOtherSpeakers)

        appState.ignoreOtherSpeakers = false

        XCTAssertEqual(defaults.object(forKey: "ignoreOtherSpeakers") as? Bool, false)
    }

    func testAppStateDefaultsPostPasteLearningToEnabled() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        XCTAssertTrue(appState.postPasteLearningEnabled)
        XCTAssertTrue(appState.postPasteLearningCoordinator.learningEnabled)
    }

    func testAppStateUpdatePostPasteLearningPersistsAndUpdatesCoordinator() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        appState.postPasteLearningEnabled = false

        XCTAssertFalse(appState.postPasteLearningEnabled)
        XCTAssertFalse(appState.postPasteLearningCoordinator.learningEnabled)
        XCTAssertEqual(defaults.object(forKey: "postPasteLearningEnabled") as? Bool, false)
    }

    func testAppStateDefaultsSoundsEnabled() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        XCTAssertTrue(appState.playSounds)
    }

    func testAppStatePersistsSoundPreference() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        appState.playSounds = false

        XCTAssertFalse(appState.playSounds)
        XCTAssertEqual(defaults.object(forKey: "playSounds") as? Bool, false)

        let reloadedAppState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        XCTAssertFalse(reloadedAppState.playSounds)
    }

    func testPrepareRecordingSessionStreamsChunksToDiarizationAndTranscriptionSessions() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let transcriptionSession = FakeRecordingTranscriptionSession(finalTranscript: "streamed transcript")
        var diarizationChunks: [[Float]] = []

        appState.speechModel = SpeechModelCatalog.parakeetV3.id
        appState.ignoreOtherSpeakers = true
        appState.recordingTranscriptionSessionFactory = { descriptor in
            XCTAssertEqual(descriptor, SpeechModelCatalog.parakeetV3)
            return transcriptionSession
        }
        appState.recordingSessionCoordinatorFactory = {
            RecordingSessionCoordinator(
                appendAudioChunk: { samples in
                    diarizationChunks.append(samples)
                },
                finish: {
                    (nil, Self.makeDiarizationSummary(usedFallback: true))
                }
            )
        }

        await appState.prepareRecordingSessionIfNeeded()
        appState.audioRecorder.onConvertedAudioChunk?([1, 2, 3, 4])

        XCTAssertNotNil(appState.activeRecordingSessionCoordinator)
        XCTAssertEqual(diarizationChunks, [[1, 2, 3, 4]])
        XCTAssertEqual(transcriptionSession.appendedChunks, [[1, 2, 3, 4]])
    }

    func testAppStateUsesRecordingTranscriptionSessionBeforeBatchFallback() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let transcriptionSession = FakeRecordingTranscriptionSession(finalTranscript: "streamed transcript")
        let cleanedInputs = LockedValue<[String]>([])
        var batchTranscriptionCallCount = 0

        appState.speechModel = SpeechModelCatalog.parakeetV3.id
        appState.recordingTranscriptionSessionFactory = { descriptor in
            XCTAssertEqual(descriptor, SpeechModelCatalog.parakeetV3)
            return transcriptionSession
        }
        appState.transcribeAudioBufferOverride = { _ in
            batchTranscriptionCallCount += 1
            return "batch transcript"
        }
        appState.cleanedTranscriptionResultOverride = { text, _ in
            await cleanedInputs.append(text)
            return (text: text, prompt: "", attemptedCleanup: false, cleanupUsedFallback: false)
        }

        await appState.prepareRecordingSessionIfNeeded()
        appState.audioRecorder.onConvertedAudioChunk?([1, 2, 3])
        appState.audioRecorder.onConvertedAudioChunk?([4, 5, 6])

        await appState.finishRecordingForTesting(
            audioBuffer: [1, 2, 3, 4, 5, 6],
            recordingSessionCoordinator: nil,
            recordingTranscriptionSession: appState.activeRecordingTranscriptionSession,
            archivedWindowContext: nil
        )

        XCTAssertEqual(transcriptionSession.appendedChunks, [[1, 2, 3], [4, 5, 6]])
        XCTAssertEqual(transcriptionSession.finishCallCount, 1)
        XCTAssertEqual(batchTranscriptionCallCount, 0)
        let recordedCleanupInputs = await cleanedInputs.get()
        XCTAssertEqual(recordedCleanupInputs, ["streamed transcript"])
    }

    func testAppStateSkipsBatchFallbackWhenRecordingSessionDisallowsIt() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let transcriptionSession = FakeRecordingTranscriptionSession(finalTranscript: nil)
        var batchTranscriptionCallCount = 0

        appState.speechModel = SpeechModelCatalog.parakeetV3.id
        appState.recordingTranscriptionSessionFactory = { descriptor in
            XCTAssertEqual(descriptor, SpeechModelCatalog.parakeetV3)
            return transcriptionSession
        }
        appState.transcribeAudioBufferOverride = { _ in
            batchTranscriptionCallCount += 1
            return "batch transcript"
        }

        await appState.prepareRecordingSessionIfNeeded()
        appState.audioRecorder.onConvertedAudioChunk?([1, 2, 3])
        appState.audioRecorder.onConvertedAudioChunk?([4, 5, 6])

        await appState.finishRecordingForTesting(
            audioBuffer: [1, 2, 3, 4, 5, 6],
            recordingSessionCoordinator: nil,
            recordingTranscriptionSession: appState.activeRecordingTranscriptionSession,
            archivedWindowContext: nil
        )

        XCTAssertEqual(transcriptionSession.finishCallCount, 1)
        XCTAssertEqual(batchTranscriptionCallCount, 0)
    }

    func testAppStateFallsBackToBatchTranscriptionWhenRecordingSessionAllowsIt() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let transcriptionSession = FakeRecordingTranscriptionSession(
            finalTranscript: nil,
            allowsBatchFallback: true
        )
        let cleanedInputs = LockedValue<[String]>([])
        var batchTranscriptionCallCount = 0

        appState.speechModel = SpeechModelCatalog.parakeetV3.id
        appState.recordingTranscriptionSessionFactory = { descriptor in
            XCTAssertEqual(descriptor, SpeechModelCatalog.parakeetV3)
            return transcriptionSession
        }
        appState.transcribeAudioBufferOverride = { _ in
            batchTranscriptionCallCount += 1
            return "batch transcript"
        }
        appState.cleanedTranscriptionResultOverride = { text, _ in
            await cleanedInputs.append(text)
            return (text: text, prompt: "", attemptedCleanup: false, cleanupUsedFallback: false)
        }

        await appState.prepareRecordingSessionIfNeeded()
        appState.audioRecorder.onConvertedAudioChunk?([1, 2, 3])
        appState.audioRecorder.onConvertedAudioChunk?([4, 5, 6])

        await appState.finishRecordingForTesting(
            audioBuffer: [1, 2, 3, 4, 5, 6],
            recordingSessionCoordinator: nil,
            recordingTranscriptionSession: appState.activeRecordingTranscriptionSession,
            archivedWindowContext: nil
        )

        XCTAssertEqual(transcriptionSession.finishCallCount, 1)
        XCTAssertEqual(batchTranscriptionCallCount, 1)
        let recordedCleanupInputs = await cleanedInputs.get()
        XCTAssertEqual(recordedCleanupInputs, ["batch transcript"])
    }

    func testAppStateFallsBackToBatchTranscriptionWhenSlidingWindowStreamReturnsNothing() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let streamedChunks = LockedValue<[[Float]]>([])
        let streamingEvents = LockedValue<[String]>([])
        let cleanedInputs = LockedValue<[String]>([])
        var batchTranscriptionCallCount = 0

        appState.speechModel = SpeechModelCatalog.parakeetV3.id
        appState.recordingTranscriptionSessionFactory = { descriptor in
            XCTAssertEqual(descriptor, SpeechModelCatalog.parakeetV3)
            return SlidingWindowRecordingTranscriptionSession {
                StreamingRecordingHandle(
                    appendAudioChunk: { samples in
                        await streamedChunks.append(samples)
                    },
                    finishTranscription: {
                        await streamingEvents.append("finish")
                        return ""
                    },
                    cancel: {
                        await streamingEvents.append("cancel")
                    },
                    cleanup: {
                        await streamingEvents.append("cleanup")
                    }
                )
            }
        }
        appState.transcribeAudioBufferOverride = { _ in
            batchTranscriptionCallCount += 1
            return "batch transcript"
        }
        appState.cleanedTranscriptionResultOverride = { text, _ in
            await cleanedInputs.append(text)
            return (text: text, prompt: "", attemptedCleanup: false, cleanupUsedFallback: false)
        }

        await appState.prepareRecordingSessionIfNeeded()
        appState.audioRecorder.onConvertedAudioChunk?([1, 2, 3])
        appState.audioRecorder.onConvertedAudioChunk?([4, 5, 6])

        await appState.finishRecordingForTesting(
            audioBuffer: [1, 2, 3, 4, 5, 6],
            recordingSessionCoordinator: nil,
            recordingTranscriptionSession: appState.activeRecordingTranscriptionSession,
            archivedWindowContext: nil
        )

        XCTAssertEqual(batchTranscriptionCallCount, 1)
        let recordedChunks = await streamedChunks.get()
        XCTAssertEqual(recordedChunks, [[1, 2, 3], [4, 5, 6]])
        let recordedEvents = await streamingEvents.get()
        XCTAssertEqual(recordedEvents, ["finish", "cleanup"])
        let recordedCleanupInputs = await cleanedInputs.get()
        XCTAssertEqual(recordedCleanupInputs, ["batch transcript"])
    }

    func testAppStateDoesNotRunExternalBatchFallbackWhenSlidingWindowSessionOwnsFinalBatchTranscription() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let streamedChunks = LockedValue<[[Float]]>([])
        let streamingEvents = LockedValue<[String]>([])
        var batchTranscriptionCallCount = 0

        appState.speechModel = SpeechModelCatalog.parakeetV3.id
        appState.recordingTranscriptionSessionFactory = { descriptor in
            XCTAssertEqual(descriptor, SpeechModelCatalog.parakeetV3)
            return SlidingWindowRecordingTranscriptionSession(
                fullBufferTranscription: { _ in nil },
                handleFactory: {
                    StreamingRecordingHandle(
                        appendAudioChunk: { samples in
                            await streamedChunks.append(samples)
                        },
                        finishTranscription: {
                            await streamingEvents.append("finish")
                            return "streamed transcript"
                        },
                        cancel: {
                            await streamingEvents.append("cancel")
                        },
                        cleanup: {
                            await streamingEvents.append("cleanup")
                        }
                    )
                }
            )
        }
        appState.transcribeAudioBufferOverride = { _ in
            batchTranscriptionCallCount += 1
            return "batch transcript"
        }

        await appState.prepareRecordingSessionIfNeeded()
        appState.audioRecorder.onConvertedAudioChunk?([1, 2, 3])
        appState.audioRecorder.onConvertedAudioChunk?([4, 5, 6])

        await appState.finishRecordingForTesting(
            audioBuffer: [1, 2, 3, 4, 5, 6],
            recordingSessionCoordinator: nil,
            recordingTranscriptionSession: appState.activeRecordingTranscriptionSession,
            archivedWindowContext: nil
        )

        XCTAssertEqual(batchTranscriptionCallCount, 0)
        let recordedChunks = await streamedChunks.get()
        XCTAssertEqual(recordedChunks, [[1, 2, 3], [4, 5, 6]])
        let recordedEvents = await streamingEvents.get()
        XCTAssertEqual(recordedEvents, ["finish", "cleanup"])
    }

    func testFinishRecordingForTestingSkipsWindowContextProviderWhenTranscriptIsMissing() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let providerCallCount = LockedValue(0)

        appState.transcribeAudioBufferOverride = { _ in
            nil
        }

        await appState.finishRecordingForTesting(
            audioBuffer: [1, 2, 3, 4],
            recordingSessionCoordinator: nil,
            recordingTranscriptionSession: nil,
            archivedWindowContext: nil,
            windowContextProvider: {
                await providerCallCount.set(1)
                return RecordingOCRPrefetchResult(
                    context: OCRContext(windowContents: "captured"),
                    elapsed: 0.25
                )
            }
        )

        let callCount = await providerCallCount.get()
        XCTAssertEqual(callCount, 0)
    }

    func testAppStatePrefersFilteredSpeakerTranscriptOverStreamedTranscript() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let transcriptionSession = FakeRecordingTranscriptionSession(finalTranscript: "streamed transcript")
        let cleanedInputs = LockedValue<[String]>([])
        var batchTranscriptionCallCount = 0
        let coordinator = RecordingSessionCoordinator(
            appendAudioChunk: { _ in },
            finish: {
                ("speaker filtered transcript", Self.makeDiarizationSummary(usedFallback: false))
            }
        )

        appState.transcribeAudioBufferOverride = { _ in
            batchTranscriptionCallCount += 1
            return "batch transcript"
        }
        appState.cleanedTranscriptionResultOverride = { text, _ in
            await cleanedInputs.append(text)
            return (text: text, prompt: "", attemptedCleanup: false, cleanupUsedFallback: false)
        }

        await appState.finishRecordingForTesting(
            audioBuffer: [1, 2, 3, 4],
            recordingSessionCoordinator: coordinator,
            recordingTranscriptionSession: transcriptionSession,
            archivedWindowContext: nil
        )

        let recordedCleanupInputs = await cleanedInputs.get()
        XCTAssertEqual(recordedCleanupInputs, ["speaker filtered transcript"])
        XCTAssertEqual(transcriptionSession.cancelCallCount, 1)
        XCTAssertEqual(transcriptionSession.finishCallCount, 0)
        XCTAssertEqual(batchTranscriptionCallCount, 0)
    }

    func testSoundEffectsSkipPlaybackWhenDisabled() {
        var startPlayCount = 0
        var stopPlayCount = 0
        let soundEffects = SoundEffects(
            isEnabled: { false },
            startPlayer: { startPlayCount += 1 },
            stopPlayer: { stopPlayCount += 1 }
        )

        soundEffects.playStart()
        soundEffects.playStop()

        XCTAssertEqual(startPlayCount, 0)
        XCTAssertEqual(stopPlayCount, 0)
    }

    func testAppStateRelaunchAppUsesConfiguredRelauncher() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let relauncher = FakeAppRelauncher()
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            appRelauncher: relauncher
        )

        appState.relaunchApp()

        XCTAssertEqual(relauncher.relaunchCallCount, 1)
        XCTAssertNil(appState.errorMessage)
    }

    func testAppStateRelaunchAppSurfacesRelaunchFailures() throws {
        struct RelaunchError: LocalizedError {
            var errorDescription: String? { "open failed" }
        }

        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let relauncher = FakeAppRelauncher()
        relauncher.error = RelaunchError()
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            appRelauncher: relauncher
        )

        appState.relaunchApp()

        XCTAssertEqual(relauncher.relaunchCallCount, 1)
        XCTAssertEqual(appState.errorMessage, "Failed to relaunch Diction: open failed")
    }

    func testAppStateShowSettingsReusesSingleWindow() throws {
        closeWindows(titled: "Diction Settings")
        defer { closeWindows(titled: "Diction Settings") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        appState.showSettings()
        appState.showSettings()

        let windows = NSApp.windows.filter { $0.title == "Diction Settings" }
        defer { windows.forEach { $0.close() } }

        XCTAssertEqual(windows.count, 1)
    }

    func testTranscriptionLabWorkshopUsesCollapsiblePipelineSections() throws {
        let source = try settingsWindowSource()

        XCTAssertTrue(source.contains("TranscriptionLabWorkshopSummary"))
        XCTAssertTrue(source.contains("TranscriptionLabSourceRecordingSummary"))
        XCTAssertTrue(source.contains("TranscriptionLabStageDisclosure"))
        XCTAssertTrue(source.contains("Rerun transcription"))
        XCTAssertTrue(source.contains("Rerun speaker tagging"))
        XCTAssertTrue(source.contains("Rerun cleanup"))
        XCTAssertFalse(source.contains("TranscriptionLabStageCard(\"Recording\")"))
    }

    func testTranscriptionLabWorkshopUsesSharedOutputComparisonViews() throws {
        let source = try settingsWindowSource()

        XCTAssertGreaterThanOrEqual(source.components(separatedBy: "TranscriptionLabOutputComparison").count - 1, 3)
        XCTAssertTrue(source.contains("Original timeline"))
        XCTAssertTrue(source.contains("New timeline"))
        XCTAssertTrue(source.contains("Matched to"))
    }

    func testTranscriptionLabWorkshopKeepsSummaryMetadataReadable() throws {
        let source = try settingsWindowSource()

        XCTAssertTrue(source.contains("TranscriptionLabMetadataLine"))
        XCTAssertTrue(source.contains("TranscriptionLabMetadataItem"))
        XCTAssertTrue(source.contains(".lineLimit(1)"))
        XCTAssertTrue(source.contains(".fixedSize(horizontal: true, vertical: false)"))
    }

    func testTranscriptionLabStageHeadersUseFullWidthButtons() throws {
        let source = try settingsWindowSource()

        XCTAssertTrue(source.contains("TranscriptionLabStageHeaderButton"))
        XCTAssertTrue(source.contains("isExpanded.toggle()"))
        XCTAssertTrue(source.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(source.contains("DisclosureGroup(isExpanded: $isExpanded)"))
    }

    private func settingsWindowSource() throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryURL
            .appendingPathComponent("Diction")
            .appendingPathComponent("UI")
            .appendingPathComponent("SettingsWindow.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    func testAppStateShortcutCaptureSuspendsHotkeyMonitor() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        let appState = AppState(
            hotkeyMonitor: monitor,
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        appState.setShortcutCaptureActive(true)
        appState.setShortcutCaptureActive(false)

        XCTAssertEqual(monitor.suspendedStates, [true, false])
    }

    func testRecordingOverlayHostsSwiftUIViaContentViewController() throws {
        let overlay = RecordingOverlayController()
        let existingWindowNumbers = Set(NSApp.windows.map(\.windowNumber))

        overlay.show()

        let panel = try XCTUnwrap(
            NSApp.windows
                .filter { !existingWindowNumbers.contains($0.windowNumber) }
                .compactMap { $0 as? NSPanel }
                .first
        )
        defer {
            overlay.dismiss()
            panel.close()
        }

        XCTAssertNotNil(panel.contentViewController)
    }

    func testAppStateLoadsPersistedCorrectionSettingsIntoStore() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let seededStore = CorrectionStore(defaults: defaults)
        seededStore.preferredTranscriptionsText = "Klein Blue\nJesse"
        seededStore.commonlyMisheardText = "just see -> Jesse"

        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        XCTAssertEqual(appState.correctionStore.preferredTranscriptions, ["Klein Blue", "Jesse"])
        XCTAssertEqual(
            appState.correctionStore.commonlyMisheard,
            [MisheardReplacement(wrong: "just see", right: "Jesse")]
        )
    }

    func testAppStateUsesPreferredTranscriptionsAsOCRCustomWords() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        appState.correctionStore.preferredTranscriptionsText = "Klein Blue\nJesse"

        XCTAssertEqual(appState.ocrCustomWords, ["Klein Blue", "Jesse"])
    }

    func testAppStateLoadsLocalCleanupModelsWhenCleanupIsEnabled() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        appState.cleanupEnabled = true

        XCTAssertTrue(appState.shouldLoadLocalCleanupModels)
    }

    func testAppStateRecordsCleanupDebugSnapshotOnlyWhileDebugViewerIsOpen() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let debugLogStore = makeDebugLogStore()
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            debugLogStore: debugLogStore
        )

        appState.recordCleanupDebugSnapshot(
            rawTranscription: "raw text",
            windowContext: OCRContext(windowContents: "window text"),
            cleanedOutput: "cleaned text",
            attemptedCleanup: true
        )
        XCTAssertTrue(debugLogStore.formattedText.isEmpty)

        debugLogStore.beginLiveViewing()
        appState.recordCleanupDebugSnapshot(
            rawTranscription: "raw text",
            windowContext: OCRContext(windowContents: "window text"),
            cleanedOutput: "cleaned text",
            attemptedCleanup: true
        )
        debugLogStore.endLiveViewing()

        let formattedText = debugLogStore.formattedText
        XCTAssertTrue(formattedText.contains("raw text"))
        XCTAssertTrue(formattedText.contains("windowContext=captured"))
        XCTAssertTrue(formattedText.contains("cleaned text"))
    }

    func testAppStateReturnsRawTranscriptionWhenCleanupModelIsUnavailable() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        correctionStore.commonlyMisheardText = "just see -> Jesse"
        let cleanupManager = TextCleanupManager(
            defaults: defaults,
            cleanupModelAvailabilityOverrides: Dictionary(
                uniqueKeysWithValues: LocalCleanupModelKind.allCases.map { ($0, false) }
            )
        )
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            textCleanupManager: cleanupManager,
            correctionStore: correctionStore
        )
        appState.cleanupEnabled = true

        let result = await appState.cleanedTranscription("just see approved it")

        XCTAssertEqual(result, "just see approved it")
    }

    func testAppStatePrepareForTerminationShutsDownCleanupBackend() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        var shutdownCount = 0
        let cleanupManager = TextCleanupManager(
            defaults: defaults,
            backendShutdownOverride: {
                shutdownCount += 1
            }
        )
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            textCleanupManager: cleanupManager
        )

        appState.prepareForTermination()

        XCTAssertEqual(shutdownCount, 1)
    }

    func testWhisperRecordingIgnoresSpeakerFilteringSetting() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        appState.speechModel = SpeechModelCatalog.whisperSmallEnglish.id
        appState.ignoreOtherSpeakers = true

        var factoryCallCount = 0
        appState.recordingSessionCoordinatorFactory = {
            factoryCallCount += 1
            return RecordingSessionCoordinator(
                appendAudioChunk: { _ in },
                finish: {
                    (filteredTranscript: "unused", summary: Self.makeDiarizationSummary(usedFallback: false))
                }
            )
        }

        await appState.prepareRecordingSessionIfNeeded()

        XCTAssertEqual(factoryCallCount, 0)
        XCTAssertNil(appState.audioRecorder.onConvertedAudioChunk)
    }

    func testQwenRecordingUsesSpeakerFilteringSession() async throws {
        guard #available(macOS 15, iOS 18, *) else {
            throw XCTSkip("Qwen3-ASR requires macOS 15 or later.")
        }

        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let transcriptionSession = FakeRecordingTranscriptionSession(finalTranscript: "streamed transcript")
        var diarizationChunks: [[Float]] = []
        var factoryCallCount = 0

        appState.speechModel = SpeechModelCatalog.qwen3AsrInt8.id
        appState.ignoreOtherSpeakers = true
        appState.recordingTranscriptionSessionFactory = { descriptor in
            XCTAssertEqual(descriptor, SpeechModelCatalog.qwen3AsrInt8)
            return transcriptionSession
        }
        appState.recordingSessionCoordinatorFactory = {
            factoryCallCount += 1
            return RecordingSessionCoordinator(
                appendAudioChunk: { samples in
                    diarizationChunks.append(samples)
                },
                finish: {
                    (nil, Self.makeDiarizationSummary(usedFallback: true))
                }
            )
        }

        await appState.prepareRecordingSessionIfNeeded()
        appState.audioRecorder.onConvertedAudioChunk?([1, 2, 3, 4])

        XCTAssertEqual(factoryCallCount, 1)
        XCTAssertNotNil(appState.activeRecordingSessionCoordinator)
        XCTAssertEqual(diarizationChunks, [[1, 2, 3, 4]])
        XCTAssertEqual(transcriptionSession.appendedChunks, [[1, 2, 3, 4]])
    }

    func testAppStateForwardsModelManagerChanges() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(chordBindingStore: ChordBindingStore(defaults: defaults))
        let expectation = expectation(description: "app state forwards speech model changes")
        var cancellable: AnyCancellable? = appState.objectWillChange.sink {
            expectation.fulfill()
        }

        appState.modelManager.objectWillChange.send()

        await fulfillment(of: [expectation], timeout: 1.0)
        withExtendedLifetime(cancellable) {}
        cancellable = nil
    }

    func testAppStateForwardsCleanupManagerChanges() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(chordBindingStore: ChordBindingStore(defaults: defaults))
        let expectation = expectation(description: "app state forwards cleanup model changes")
        var cancellable: AnyCancellable? = appState.objectWillChange.sink {
            expectation.fulfill()
        }

        appState.textCleanupManager.objectWillChange.send()

        await fulfillment(of: [expectation], timeout: 1.0)
        withExtendedLifetime(cancellable) {}
        cancellable = nil
    }

    private func closeWindows(titled title: String) {
        NSApp.windows
            .filter { $0.title == title }
            .forEach { window in
                window.delegate = nil
                window.orderOut(nil)
                window.close()
            }
    }

    func testCheckMicrophoneUsesInjectedClientWithoutSystemPrompt() async {
        var requestCount = 0
        PermissionChecker.current = PermissionChecker.Client(
            checkAccessibility: { false },
            promptAccessibility: {},
            microphoneStatus: { .notDetermined },
            requestMicrophoneAccess: {
                requestCount += 1
                return true
            },
            openAccessibilitySettings: {},
            openMicrophoneSettings: {}
        )

        let granted = await PermissionChecker.checkMicrophone()

        XCTAssertTrue(granted)
        XCTAssertEqual(requestCount, 1)
    }

    func testDefaultClientIsNonInteractiveDuringTests() async {
        PermissionChecker.current = PermissionChecker.defaultClient

        let granted = await PermissionChecker.checkMicrophone()

        XCTAssertFalse(granted)
        XCTAssertEqual(PermissionChecker.microphoneStatus(), .denied)
    }

    func testAudioDeviceManagerPersistsSelectedDeviceUID() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        AudioDeviceManager.setSelectedInputDevice(157, defaults: defaults) { deviceID in
            XCTAssertEqual(deviceID, 157)
            return "studio-display"
        }

        XCTAssertEqual(defaults.string(forKey: "selectedInputDeviceUID"), "studio-display")
    }

    func testAudioDeviceManagerMigratesLegacyDeviceIDToUIDAndResolvesCurrentDeviceID() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set(157, forKey: "selectedInputDeviceID")

        let migratedID = AudioDeviceManager.selectedInputDeviceID(
            defaults: defaults,
            inputDevices: {
                [AudioInputDevice(id: 157, uid: "studio-display", name: "Studio Display Microphone")]
            }
        )
        let resolvedID = AudioDeviceManager.selectedInputDeviceID(
            defaults: defaults,
            inputDevices: {
                [AudioInputDevice(id: 142, uid: "studio-display", name: "Studio Display Microphone")]
            }
        )

        XCTAssertEqual(migratedID, 157)
        XCTAssertEqual(resolvedID, 142)
        XCTAssertEqual(defaults.string(forKey: "selectedInputDeviceUID"), "studio-display")
    }

    func testAudioDeviceManagerIgnoresStaleLegacyDeviceIDThatIsNotCurrentlyAvailable() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set(157, forKey: "selectedInputDeviceID")

        let resolvedID = AudioDeviceManager.selectedInputDeviceID(
            defaults: defaults,
            inputDevices: {
                [AudioInputDevice(id: 142, uid: "studio-display", name: "Studio Display Microphone")]
            }
        )

        XCTAssertNil(resolvedID)
        XCTAssertNil(defaults.string(forKey: "selectedInputDeviceUID"))
    }

    func testAudioDeviceManagerResolvesCurrentDeviceIDFromSavedUID() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set("studio-display", forKey: "selectedInputDeviceUID")

        let resolvedID = AudioDeviceManager.selectedInputDeviceID(
            defaults: defaults,
            inputDevices: {
                [AudioInputDevice(id: 142, uid: "studio-display", name: "Studio Display Microphone")]
            }
        )

        XCTAssertEqual(resolvedID, 142)
    }

    func testAudioDeviceManagerReturnsNilWhenSavedUIDDoesNotResolve() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set("missing-device", forKey: "selectedInputDeviceUID")

        let resolvedID = AudioDeviceManager.selectedInputDeviceID(
            defaults: defaults,
            inputDevices: { [] }
        )

        XCTAssertNil(resolvedID)
    }

    func testAudioDeviceManagerPreferredInputDeviceFallsBackToSystemDefault() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let resolvedID = AudioDeviceManager.preferredInputDeviceID(
            defaults: defaults,
            inputDevices: {
                [
                    AudioInputDevice(id: 142, uid: "studio-display", name: "Studio Display Microphone"),
                    AudioInputDevice(id: 314, uid: "usb-mic", name: "USB Microphone"),
                ]
            },
            defaultInputDeviceIDProvider: { 314 }
        )

        XCTAssertEqual(resolvedID, 314)
    }

    func testAudioDeviceManagerPreferredInputDeviceFallsBackToFirstAvailableMicrophone() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let resolvedID = AudioDeviceManager.preferredInputDeviceID(
            defaults: defaults,
            inputDevices: {
                [
                    AudioInputDevice(id: 142, uid: "studio-display", name: "Studio Display Microphone"),
                    AudioInputDevice(id: 314, uid: "usb-mic", name: "USB Microphone"),
                ]
            },
            defaultInputDeviceIDProvider: { 999 }
        )

        XCTAssertEqual(resolvedID, 142)
    }

    func testResetAudioEngineClearsLiveRecordingNoInputErrorWhenIdle() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        var resetCallCount = 0
        let appState = AppState(
            chordBindingStore: ChordBindingStore(defaults: defaults),
            selectedInputDeviceIDProvider: { 142 },
            resetAudioRecorder: {
                resetCallCount += 1
            }
        )
        appState.status = .error
        appState.errorMessage = AppState.liveRecordingNoInputErrorMessage

        appState.resetAudioEngine()

        XCTAssertEqual(appState.audioRecorder.targetDeviceID, 142)
        XCTAssertEqual(resetCallCount, 1)
        XCTAssertEqual(appState.status, .ready)
        XCTAssertNil(appState.errorMessage)
    }

    func testResetAudioEngineKeepsUnrelatedErrorState() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        var resetCallCount = 0
        let appState = AppState(
            chordBindingStore: ChordBindingStore(defaults: defaults),
            selectedInputDeviceIDProvider: { nil },
            resetAudioRecorder: {
                resetCallCount += 1
            }
        )
        appState.status = .error
        appState.errorMessage = "Microphone access required"

        appState.resetAudioEngine()

        XCTAssertEqual(resetCallCount, 1)
        XCTAssertEqual(appState.status, .error)
        XCTAssertEqual(appState.errorMessage, "Microphone access required")
    }

    private static func makeArchiveableAudioBuffer(sampleCount: Int = 1_600) -> [Float] {
        Array(repeating: 0.1, count: sampleCount)
    }

    private static func makeDiarizationSummary(usedFallback: Bool) -> DiarizationSummary {
        DiarizationSummary(
            spans: [
                DiarizationSummary.Span(speakerID: "speaker-a", startTime: 0.0, endTime: 0.8, isKept: true),
                DiarizationSummary.Span(speakerID: "speaker-b", startTime: 0.9, endTime: 1.2, isKept: false)
            ],
            mergedKeptSpans: [
                DiarizationSummary.MergedSpan(startTime: 0.0, endTime: 0.8)
            ],
            targetSpeakerID: "speaker-a",
            targetSpeakerDuration: 0.8,
            keptAudioDuration: 0.8,
            usedFallback: usedFallback,
            fallbackReason: usedFallback ? .emptyFilteredTranscription : nil
        )
    }
}

private actor LockedValue<Value> {
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        value
    }

    func set(_ value: Value) {
        self.value = value
    }

    func append<Element>(_ newElement: Element) where Value == [Element] {
        value.append(newElement)
    }
}
