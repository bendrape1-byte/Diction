import SwiftUI
import Combine
import CoreAudio
import ServiceManagement

enum AppStatus: String {
    case ready = "Ready"
    case loading = "Loading model..."
    case recording = "Recording..."
    case transcribing = "Transcribing..."
    case cleaningUp = "Cleaning up..."
    case error = "Error"
}

enum EmptyTranscriptionDisposition: Equatable {
    case cancel
    case showNoSoundDetected
}

@MainActor
class AppState: ObservableObject {
    enum PipelineOwner {
        case liveRecording
    }

    typealias CleanupResult = (
        text: String,
        prompt: String,
        attemptedCleanup: Bool,
        cleanupUsedFallback: Bool
    )
    typealias WindowContextProvider = @MainActor () async -> RecordingOCRPrefetchResult?

    private struct RecordingTranscriptionResult {
        let rawTranscription: String?
        let speakerFilteringRan: Bool
        let diarizationSummary: DiarizationSummary?
    }

    @Published var status: AppStatus = .loading
    @Published var isRecording: Bool = false
    @Published var errorMessage: String?
    @Published var shortcutErrorMessage: String?
    @Published var cleanupBackend: CleanupBackendOption {
        didSet {
            cleanupSettingsDefaults.set(cleanupBackend.rawValue, forKey: Self.cleanupBackendDefaultsKey)
        }
    }
    @Published var frontmostWindowContextEnabled: Bool {
        didSet {
            cleanupSettingsDefaults.set(
                frontmostWindowContextEnabled,
                forKey: Self.frontmostWindowContextEnabledDefaultsKey
            )
        }
    }
    @Published var playSounds: Bool {
        didSet {
            cleanupSettingsDefaults.set(
                playSounds,
                forKey: Self.playSoundsDefaultsKey
            )
        }
    }
    @Published private(set) var alwaysAllowedPasteApplications: [PasteTargetApplication] = []
    @AppStorage("cleanupEnabled") var cleanupEnabled: Bool = true
    @AppStorage("cleanupPrompt") var cleanupPrompt: String = TextCleaner.defaultPrompt
    @AppStorage("speechModel") var speechModel: String = SpeechModelCatalog.defaultModelID
    @AppStorage("preferredLanguage") var preferredLanguage: String = "auto"
    @AppStorage("meetingTranscriptEnabled") var meetingTranscriptEnabled: Bool = false
    @AppStorage("meetingAutoDetectEnabled") var meetingAutoDetectEnabled: Bool = true
    @AppStorage("pauseMediaWhileRecording") var pauseMediaWhileRecording: Bool = true
    @Published private(set) var pushToTalkChord: KeyChord
    @Published private(set) var toggleToTalkChord: KeyChord
    @Published var postPasteLearningEnabled: Bool {
        didSet {
            cleanupSettingsDefaults.set(
                postPasteLearningEnabled,
                forKey: Self.postPasteLearningEnabledDefaultsKey
            )
            postPasteLearningCoordinator.learningEnabled = postPasteLearningEnabled
        }
    }
    @Published var ignoreOtherSpeakers: Bool {
        didSet {
            cleanupSettingsDefaults.set(
                ignoreOtherSpeakers,
                forKey: Self.ignoreOtherSpeakersDefaultsKey
            )
        }
    }

    let modelManager: ModelManager
    let audioRecorder: AudioRecorder
    let transcriber: SpeechTranscriber
    let textPaster: TextPaster
    lazy var soundEffects = SoundEffects(isEnabled: { [weak self] in
        self?.playSounds ?? true
    })
    private lazy var mediaPlaybackController = MediaPlaybackController(enabled: { [weak self] in
        self?.pauseMediaWhileRecording ?? true
    })
    let hotkeyMonitor: HotkeyMonitoring
    let overlay = RecordingOverlayController()
    let textCleanupManager: TextCleanupManager
    let frontmostWindowOCRService: FrontmostWindowOCRService
    let cleanupPromptBuilder: CleanupPromptBuilder
    let correctionStore: CorrectionStore
    let textCleaner: TextCleaner
    let chordBindingStore: ChordBindingStore
    let postPasteLearningCoordinator: PostPasteLearningCoordinator
    let debugLogStore: DebugLogStore
    let appRelauncher: AppRelaunching
    var recordingSessionCoordinatorFactory: (() -> RecordingSessionCoordinator?)?
    var recordingTranscriptionSessionFactory: ((SpeechModelDescriptor) -> RecordingTranscriptionSession?)?
    var transcribeAudioBufferOverride: (([Float]) -> String?)?
    var cleanedTranscriptionResultOverride: ((String, OCRContext?) async -> CleanupResult)?
    private(set) var activeRecordingSessionCoordinator: RecordingSessionCoordinator?
    private(set) var activeRecordingTranscriptionSession: RecordingTranscriptionSession?

    var isReady: Bool {
        status == .ready
    }

    static func emptyTranscriptionDisposition(forAudioSampleCount sampleCount: Int) -> EmptyTranscriptionDisposition {
        if sampleCount < emptyTranscriptionCancelThresholdSampleCount {
            return .cancel
        }

        return .showNoSoundDetected
    }

    private var cleanupStateObserver: AnyCancellable?
    private var modelStateObserver: AnyCancellable?
    private var pushToTalkChordObserver: AnyCancellable?
    private let recordingOCRPrefetch: RecordingOCRPrefetch
    private var activePerformanceTrace: PerformanceTrace?
    private var activeCleanupAttempted = false
    private var pipelineOwner: PipelineOwner?
    private var speechAnalyzerReloadsInFlight = 0
    private var pendingMeetingSessionStarts = 0
    private let cleanupSettingsDefaults: UserDefaults
    private let inputMonitoringChecker: () -> Bool
    private let inputMonitoringPrompter: () -> Void
    private let selectedInputDeviceIDProvider: () -> AudioDeviceID?
    private let resetAudioRecorder: () -> Void
    private var hotkeyMonitorStarted = false

    private static let cleanupBackendDefaultsKey = "cleanupBackend"
    private static let frontmostWindowContextEnabledDefaultsKey = "frontmostWindowContextEnabled"
    private static let postPasteLearningEnabledDefaultsKey = "postPasteLearningEnabled"
    private static let ignoreOtherSpeakersDefaultsKey = "ignoreOtherSpeakers"
    private static let playSoundsDefaultsKey = "playSounds"
    private static let alwaysAllowedPasteApplicationsDefaultsKey = "alwaysAllowedPasteApplications"
    private static let archivedRecordingSampleRate = 16_000.0
    private static let speechAnalyzerReloadPollIntervalNanoseconds: UInt64 = 10_000_000
    // History shows one decimal place, so shorter recordings render as 0.0s noise.
    private static let minimumArchivedRecordingSampleCount = 800
    private static let emptyTranscriptionCancelThresholdSampleCount = 8_000 // ~0.5 seconds — show "no sound" hint for almost all failed recordings
    private static let speechModelErrorPrefix = "Failed to load speech model: "
    static let liveRecordingNoInputErrorMessage = "Failed to start recording: No audio input device available."

    nonisolated static let defaultPushToTalkChord = KeyChord(keys: Set([
        PhysicalKey(keyCode: 54),  // Right Command
        PhysicalKey(keyCode: 61)   // Right Option
    ]))!

    nonisolated static let defaultToggleToTalkChord = KeyChord(keys: Set([
        PhysicalKey(keyCode: 54),  // Right Command
        PhysicalKey(keyCode: 61),  // Right Option
        PhysicalKey(keyCode: 49)   // Space
    ]))!

    nonisolated static let defaultShortcutBindings: [ChordAction: KeyChord] = [
        .pushToTalk: defaultPushToTalkChord,
        .toggleToTalk: defaultToggleToTalkChord
    ]

    init(
        hotkeyMonitor: HotkeyMonitoring = HotkeyMonitor(bindings: AppState.defaultShortcutBindings),
        chordBindingStore: ChordBindingStore = ChordBindingStore(),
        cleanupSettingsDefaults: UserDefaults = .standard,
        modelManager: ModelManager? = nil,
        textCleanupManager: TextCleanupManager? = nil,
        frontmostWindowOCRService: FrontmostWindowOCRService = FrontmostWindowOCRService(),
        cleanupPromptBuilder: CleanupPromptBuilder = CleanupPromptBuilder(),
        correctionStore: CorrectionStore? = nil,
        audioRecorder: AudioRecorder = AudioRecorder(),
        textPaster: TextPaster = TextPaster(),
        debugLogStore: DebugLogStore = DebugLogStore(),
        appRelauncher: AppRelaunching? = nil,
        inputMonitoringChecker: @escaping () -> Bool = PermissionChecker.checkInputMonitoring,
        inputMonitoringPrompter: @escaping () -> Void = PermissionChecker.promptInputMonitoring,
        selectedInputDeviceIDProvider: @escaping () -> AudioDeviceID? = { AudioDeviceManager.selectedInputDeviceID() },
        resetAudioRecorder: (() -> Void)? = nil
    ) {
        self.hotkeyMonitor = hotkeyMonitor
        self.chordBindingStore = chordBindingStore
        self.cleanupSettingsDefaults = cleanupSettingsDefaults
        self.modelManager = modelManager ?? ModelManager()
        self.audioRecorder = audioRecorder
        self.textPaster = textPaster
        self.debugLogStore = debugLogStore
        self.appRelauncher = appRelauncher ?? AppRelauncher()
        self.inputMonitoringChecker = inputMonitoringChecker
        self.inputMonitoringPrompter = inputMonitoringPrompter
        self.selectedInputDeviceIDProvider = selectedInputDeviceIDProvider
        self.resetAudioRecorder = resetAudioRecorder ?? { [audioRecorder] in
            audioRecorder.resetForDeviceChange()
        }
        self.pushToTalkChord = chordBindingStore.binding(for: .pushToTalk) ?? AppState.defaultPushToTalkChord
        self.toggleToTalkChord = chordBindingStore.binding(for: .toggleToTalk) ?? AppState.defaultToggleToTalkChord
        self.textCleanupManager = textCleanupManager ?? TextCleanupManager(defaults: cleanupSettingsDefaults)
        self.frontmostWindowOCRService = frontmostWindowOCRService
        self.recordingOCRPrefetch = RecordingOCRPrefetch { [frontmostWindowOCRService] customWords in
            await frontmostWindowOCRService.captureContext(customWords: customWords)
        }
        self.cleanupPromptBuilder = cleanupPromptBuilder
        self.correctionStore = correctionStore ?? CorrectionStore(defaults: cleanupSettingsDefaults)
        let storedCleanupBackend = CleanupBackendOption(
            rawValue: cleanupSettingsDefaults.string(forKey: Self.cleanupBackendDefaultsKey) ?? ""
        ) ?? .localModels
        let storedFrontmostWindowContextEnabled = cleanupSettingsDefaults.bool(
            forKey: Self.frontmostWindowContextEnabledDefaultsKey
        )
        let storedPostPasteLearningEnabled: Bool
        if cleanupSettingsDefaults.object(forKey: Self.postPasteLearningEnabledDefaultsKey) == nil {
            storedPostPasteLearningEnabled = true
        } else {
            storedPostPasteLearningEnabled = cleanupSettingsDefaults.bool(
                forKey: Self.postPasteLearningEnabledDefaultsKey
            )
        }
        let storedIgnoreOtherSpeakers: Bool
        if cleanupSettingsDefaults.object(forKey: Self.ignoreOtherSpeakersDefaultsKey) == nil {
            storedIgnoreOtherSpeakers = false
        } else {
            storedIgnoreOtherSpeakers = cleanupSettingsDefaults.bool(
                forKey: Self.ignoreOtherSpeakersDefaultsKey
            )
        }
        self.cleanupBackend = storedCleanupBackend
        self.frontmostWindowContextEnabled = storedFrontmostWindowContextEnabled
        self.postPasteLearningEnabled = storedPostPasteLearningEnabled
        self.ignoreOtherSpeakers = storedIgnoreOtherSpeakers
        self.alwaysAllowedPasteApplications = Self.loadAlwaysAllowedPasteApplications(
            defaults: cleanupSettingsDefaults
        )
        if cleanupSettingsDefaults.object(forKey: Self.playSoundsDefaultsKey) == nil {
            self.playSounds = true
        } else {
            self.playSounds = cleanupSettingsDefaults.bool(forKey: Self.playSoundsDefaultsKey)
        }
        self.transcriber = SpeechTranscriber(modelManager: self.modelManager)
        self.textCleaner = TextCleaner(
            cleanupManager: self.textCleanupManager,
            correctionStore: self.correctionStore
        )
        self.postPasteLearningCoordinator = PostPasteLearningCoordinator(
            correctionStore: self.correctionStore,
            learningEnabled: storedPostPasteLearningEnabled,
            revisit: { session in
                await PostPasteLearningObservationProvider.captureObservation(
                    for: session
                )
            }
        )

        // Forward nested model manager state changes so SwiftUI refreshes settings rows in place.
        modelStateObserver = self.modelManager.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
            }
        }

        // Forward cleanup manager state changes to trigger menu bar icon refresh.
        cleanupStateObserver = self.textCleanupManager.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
            }
        }

        cleanupSettingsDefaults.set(storedCleanupBackend.rawValue, forKey: Self.cleanupBackendDefaultsKey)
        cleanupSettingsDefaults.set(
            storedFrontmostWindowContextEnabled,
            forKey: Self.frontmostWindowContextEnabledDefaultsKey
        )
        cleanupSettingsDefaults.set(
            storedPostPasteLearningEnabled,
            forKey: Self.postPasteLearningEnabledDefaultsKey
        )
        cleanupSettingsDefaults.set(
            storedIgnoreOtherSpeakers,
            forKey: Self.ignoreOtherSpeakersDefaultsKey
        )
        cleanupSettingsDefaults.set(
            playSounds,
            forKey: Self.playSoundsDefaultsKey
        )
        persistShortcutBindingsIfNeeded()
        hotkeyMonitor.updateBindings(shortcutBindings)
        self.textPaster.onPaste = { [postPasteLearningCoordinator = self.postPasteLearningCoordinator] session in
            postPasteLearningCoordinator.handlePaste(session)
        }
        self.textPaster.configureAlwaysAllowedApplications { [weak self] bundleIdentifier in
            self?.alwaysAllowedPasteApplications.contains {
                $0.bundleIdentifier == bundleIdentifier
            } ?? false
        }
        self.audioRecorder.onRecordingStarted = { [weak self] in
            Task { @MainActor in
                self?.activePerformanceTrace?.micLiveAt = Date()
            }
        }
        self.audioRecorder.onRecordingStopped = { [weak self] in
            Task { @MainActor in
                self?.activePerformanceTrace?.micColdAt = Date()
            }
        }
        self.textPaster.onPasteStart = { [weak self] in
            Task { @MainActor in
                self?.activePerformanceTrace?.pasteStartAt = Date()
            }
        }
        self.textPaster.onPasteEnd = { [weak self] in
            Task { @MainActor in
                self?.completeActivePerformanceTraceIfNeeded()
            }
        }
        self.postPasteLearningCoordinator.onLearnedCorrection = { [weak overlay] replacement in
            Task { @MainActor in
                overlay?.show(message: .learnedCorrection(replacement))
            }
        }
        let componentDebugLogger: (DebugLogCategory, String) -> Void = { [weak debugLogStore] category, message in
            Task { @MainActor in
                debugLogStore?.record(category: category, message: message)
            }
        }
        let sensitiveComponentDebugLogger: (DebugLogCategory, String) -> Void = { [weak debugLogStore] category, message in
            Task { @MainActor in
                debugLogStore?.recordSensitive(category: category, message: message)
            }
        }
        if let hotkeyMonitor = hotkeyMonitor as? HotkeyMonitor {
            hotkeyMonitor.debugLogger = componentDebugLogger
        }
        self.textCleanupManager.debugLogger = componentDebugLogger
        self.frontmostWindowOCRService.debugLogger = componentDebugLogger
        self.frontmostWindowOCRService.sensitiveDebugLogger = sensitiveComponentDebugLogger
        self.textCleaner.debugLogger = componentDebugLogger
        self.textCleaner.sensitiveDebugLogger = sensitiveComponentDebugLogger
        self.postPasteLearningCoordinator.debugLogger = componentDebugLogger
        self.modelManager.debugLogger = componentDebugLogger
    }

    private let onboardingController = OnboardingWindowController()
    private let meetingPrompt = MeetingPromptController()
    private var didInitialize = false

    private static var hasAllPermissions: Bool {
        PermissionChecker.microphoneStatus() == .authorized && PermissionChecker.checkAccessibility()
            && PermissionChecker.checkInputMonitoring()
    }

    /// Called once at launch: first-run setup (or the permission step when one is missing), else straight to the hub.
    func start() async {
        MeetingHistory.migrateOldLayout(in: MeetingTranscriptSettings.effectiveSaveDirectory())
        let onboarded = UserDefaults.standard.bool(forKey: "onboardingCompleted")
        if !onboarded || !Self.hasAllPermissions {
            onboardingController.show(appState: self, startAtPermissions: onboarded) { [weak self] in self?.showHub() }
            return  // the onboarding's last step calls initialize()
        }
        await initialize()
        showHub()
    }

    func showPermissions() {
        onboardingController.show(appState: self, startAtPermissions: true) { [weak self] in self?.showHub() }
    }

    func initialize(skipPermissionPrompts: Bool = false) async {
        guard !didInitialize else { return }
        didInitialize = true

        // Enable launch at login by default on first run
        if !UserDefaults.standard.bool(forKey: "hasSetLaunchAtLogin") {
            UserDefaults.standard.set(true, forKey: "hasSetLaunchAtLogin")
            try? SMAppService.mainApp.register()
        }

        if !skipPermissionPrompts && !Self.hasAllPermissions {
            showPermissions()
        }

        // Wire up "no sound" overlay to open settings
        overlay.onNoSoundSettingsTapped = { [weak self] in
            self?.showSettings()
        }
        overlay.onAlwaysAllowPaste = { [weak self] in
            self?.alwaysAllowLastPasteTarget()
        }
        overlay.levelProvider = { [audioRecorder] in audioRecorder.level }
        overlay.onCancel = { [weak self] in
            Task { @MainActor in await self?.cancelRecording() }
        }
        overlay.onFinish = { [weak self] in
            Task { @MainActor in await self?.finishRecording() }
        }
        audioRecorder.onPause = { [weak self] samples in
            Task { @MainActor in self?.startEarly(samples) }
        }

        // Pre-warm audio engine so first recording starts faster
        audioRecorder.prewarm()
        FocusedElementLocator.startPasteTargetTracking()

        status = .loading
        let showOverlay = UserDefaults.standard.bool(forKey: "onboardingCompleted")
        if showOverlay {
            overlay.show(message: .modelLoading)
        }
        debugLogStore.record(category: .model, message: "App initialization started.")
        if !modelManager.isReady || modelManager.modelName != speechModel {
            await loadSpeechModel(name: speechModel)
        }
        if showOverlay {
            overlay.dismiss()
        }

        guard modelManager.isReady else {
            return
        }

        await startHotkeyMonitor()

        await refreshCleanupModelState()

        // Start meeting detection if enabled
        setupMeetingDetector()
    }

    func relaunchApp() {
        do {
            try appRelauncher.relaunch()
        } catch {
            errorMessage = "Failed to relaunch Diction: \(error.localizedDescription)"
        }
    }

    func startHotkeyMonitor() async {
        hotkeyMonitor.onRecordingStart = nil
        hotkeyMonitor.onRecordingStop = nil
        hotkeyMonitor.onRecordingRestart = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Push-to-talk upgraded to toggle — reset buffer only if recording just started
                // (less than 1 second of audio at 16kHz). If they've been talking longer, keep it.
                let sampleCount = self.audioRecorder.audioBuffer.count
                if sampleCount < 16000 {
                    self.audioRecorder.resetBuffer()
                    self.earlyStart?.transcript.cancel()  // it was taken from the audio just thrown away
                    self.earlyStart = nil
                    self.debugLogStore.record(category: .hotkey, message: "Recording restarted (push-to-talk upgraded to toggle, \(sampleCount) samples discarded).")
                } else {
                    self.debugLogStore.record(category: .hotkey, message: "Push-to-talk upgraded to toggle, keeping \(sampleCount) samples of existing audio.")
                }
                self.showHandsFree()
            }
        }

        hotkeyMonitor.onPushToTalkStart = { [weak self] in
            Task { @MainActor in
                self?.beginPerformanceTrace()
                await self?.startRecording()
            }
        }
        hotkeyMonitor.onPushToTalkStop = { [weak self] in
            Task { @MainActor in
                self?.activePerformanceTrace?.hotkeyLiftedAt = Date()
                await self?.stopRecordingAndTranscribe()
            }
        }
        hotkeyMonitor.onToggleToTalkStart = { [weak self] in
            Task { @MainActor in
                self?.beginPerformanceTrace()
                await self?.startRecording()
                self?.showHandsFree()
            }
        }
        hotkeyMonitor.onToggleToTalkStop = { [weak self] in
            Task { @MainActor in
                self?.activePerformanceTrace?.hotkeyLiftedAt = Date()
                await self?.stopRecordingAndTranscribe()
            }
        }
        hotkeyMonitor.onRecordingCancel = { [weak self] in
            Task { @MainActor in
                await self?.cancelRecording()
            }
        }

        hotkeyMonitor.updateBindings(shortcutBindings)

        if hotkeyMonitorStarted {
            debugLogStore.record(category: .hotkey, message: "Hotkey monitor start skipped because it is already active.")
            if status != .error {
                status = .ready
                errorMessage = nil
            }
            return
        }

        if !inputMonitoringChecker() {
            // Try to prompt, but don't block — Accessibility alone may be sufficient
            inputMonitoringPrompter()
            debugLogStore.record(category: .hotkey, message: "Input Monitoring not granted, attempting to start with Accessibility only.")
        }

        if hotkeyMonitor.start() {
            hotkeyMonitorStarted = true
            status = .ready
            errorMessage = nil
            debugLogStore.record(category: .hotkey, message: "Hotkey monitor is ready.")
        } else {
            PermissionChecker.promptAccessibility()
            errorMessage = "Accessibility access required — grant permission then click Retry"
            status = .error
            debugLogStore.record(category: .hotkey, message: errorMessage ?? "Accessibility access required.")
        }
    }

    func prepareRecordingSessionIfNeeded() async {
        audioRecorder.onConvertedAudioChunk = nil
        activeRecordingSessionCoordinator = nil
        activeRecordingTranscriptionSession = nil

        if let speechModelDescriptor = SpeechModelCatalog.model(named: speechModel) {
            if let recordingTranscriptionSessionFactory {
                activeRecordingTranscriptionSession = recordingTranscriptionSessionFactory(
                    speechModelDescriptor
                )
            } else if let recordingTranscriptionSession = modelManager.makeRecordingTranscriptionSession(
                language: preferredLanguage == "auto" ? nil : preferredLanguage
            ) {
                activeRecordingTranscriptionSession = recordingTranscriptionSession
            } else if speechModelDescriptor.backend == .fluidAudio {
                activeRecordingTranscriptionSession = ChunkedRecordingTranscriptionSession(
                    transcribeChunk: { [weak self] samples in
                        await self?.transcribeAudioBuffer(samples)
                    }
                )
            }
        }

        guard ignoreOtherSpeakers, selectedSpeechModelSupportsSpeakerFiltering else {
            if let activeRecordingTranscriptionSession {
                audioRecorder.onConvertedAudioChunk = { [weak activeRecordingTranscriptionSession] samples in
                    activeRecordingTranscriptionSession?.appendAudioChunk(samples)
                }
            }
            return
        }

        let coordinator: RecordingSessionCoordinator?
        if let recordingSessionCoordinatorFactory {
            coordinator = recordingSessionCoordinatorFactory()
        } else {
            coordinator = await modelManager.makeRecordingSessionCoordinator()
        }

        guard let coordinator else {
            if let activeRecordingTranscriptionSession {
                audioRecorder.onConvertedAudioChunk = { [weak activeRecordingTranscriptionSession] samples in
                    activeRecordingTranscriptionSession?.appendAudioChunk(samples)
                }
            }
            return
        }

        activeRecordingSessionCoordinator = coordinator
        audioRecorder.onConvertedAudioChunk = {
            [weak coordinator, weak activeRecordingTranscriptionSession] samples in
            coordinator?.appendAudioChunk(samples)
            activeRecordingTranscriptionSession?.appendAudioChunk(samples)
        }
    }

    private func clearRecordingSessionCoordinator() {
        audioRecorder.onConvertedAudioChunk = nil
        activeRecordingSessionCoordinator = nil
        activeRecordingTranscriptionSession = nil
    }

    private var selectedSpeechModelSupportsSpeakerFiltering: Bool {
        SpeechModelCatalog.model(named: speechModel)?.supportsSpeakerFiltering == true
    }

    private var canStartSpeechAnalyzerConsumer: Bool {
        guard SpeechModelCatalog.model(named: speechModel)?.backend == .speechAnalyzer else {
            return true
        }

        return status == .ready
            && modelManager.isReady
            && modelManager.modelName == speechModel
            && speechAnalyzerReloadsInFlight == 0
    }

    private func startRecording() async {
        // If the selected speech model isn't ready, show loading message
        guard status == .ready,
              modelManager.isReady,
              modelManager.modelName == speechModel,
              speechAnalyzerReloadsInFlight == 0 else {
            debugLogStore.record(
                category: .hotkey,
                message: "Recording start skipped because app is not ready. status=\(status.rawValue), modelReady=\(modelManager.isReady), loadedSpeechModel=\(modelManager.modelName), selectedSpeechModel=\(speechModel), speechAnalyzerReloadsInFlight=\(speechAnalyzerReloadsInFlight)"
            )
            if status == .loading
                || !modelManager.isReady
                || modelManager.modelName != speechModel
                || speechAnalyzerReloadsInFlight > 0 {
                overlay.show(message: .modelLoading)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.overlay.dismiss()
                }
            }
            return
        }

        if activePerformanceTrace == nil {
            beginPerformanceTrace()
        }

        guard acquirePipeline(for: .liveRecording) else {
            debugLogStore.record(category: .hotkey, message: "Recording start skipped because the transcription pipeline is busy.")
            activePerformanceTrace = nil
            activeCleanupAttempted = false
            return
        }

        do {
            await prepareRecordingSessionIfNeeded()
            if cleanupEnabled && canAttemptCleanup && frontmostWindowContextEnabled {
                recordingOCRPrefetch.start(customWords: ocrCustomWords)
            } else {
                recordingOCRPrefetch.cancel()
            }
            if cleanupEnabled && canAttemptCleanup {
                let promptComponents = activeCleanupPromptComponents(windowContext: nil)
                textCleanupManager.startPromptPrefill(
                    systemPromptPrefix: promptComponents.stablePromptPrefix,
                    modelKind: textCleanupManager.selectedCleanupModelKind
                )
            } else {
                textCleanupManager.cancelPromptPrefill()
            }
            mediaPlaybackController.pauseIfPlaying()
            audioRecorder.targetDeviceID = selectedInputDeviceIDProvider()
            earlyStart = nil
            try audioRecorder.startRecording()
            AnthropicCleanupBackend.warmUp()  // ready by the time the key is released
            AnthropicCleanupBackend.readAppContext()  // which app the text goes to, for the cleanup
            debugLogStore.record(category: .hotkey, message: "Recording started.")
            soundEffects.playStart()
            overlay.show(message: .recording)
            isRecording = true
            status = .recording
        } catch {
            recordingOCRPrefetch.cancel()
            releasePipeline(owner: .liveRecording)
            activePerformanceTrace = nil
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            status = .error
        }
    }

    /// Hands-free (Fn+Space) locked on: the lock sound and brackets around the line.
    private func showHandsFree() {
        guard status == .recording else { return }
        soundEffects.playLock()
        overlay.show(message: .handsFree)
    }

    private var isTranscribing = false

    /// The release work, started at the last pause in speech: the transcript of everything recorded up to
    /// `samples`, and (inside the Haiku backend) the cleanup request for it.
    private var earlyStart: (samples: Int, transcript: Task<String?, Never>)?

    /// At a pause (AudioRecorder.onPause): transcribe what's been said so far and send it to Haiku, so if
    /// nothing more is said, both are done or under way when the key is released. Your recordings: 63 %
    /// have at least 0.25 s of quiet before release, 22 % a second or more.
    // ponytail: off with speaker filtering or screen context; both add their own steps at release
    private func startEarly(_ samples: [Float]) {
        guard status == .recording, !isTranscribing, activeRecordingSessionCoordinator == nil,
              !frontmostWindowContextEnabled else { return }
        let previous = earlyStart?.transcript
        previous?.cancel()  // replaced by this newer pause
        let transcript = Task { () -> String? in
            _ = await previous?.value  // one transcription at a time, so pauses can't pile up work
            guard !Task.isCancelled else { return nil }
            return await transcribeAudioBuffer(samples)
        }
        earlyStart = (samples.count, transcript)
        guard cleanupEnabled, canAttemptCleanup else { return }
        Task {
            guard let text = await transcript.value, !transcript.isCancelled else { return }
            textCleaner.prefetch(
                text: text,
                prompt: activeCleanupPromptComponents(windowContext: nil).fullPrompt,
                modelKind: textCleanupManager.selectedCleanupModelKind
            )
        }
    }

    /// Esc: throw the recording away, nothing gets transcribed or pasted.
    func cancelRecording() async {
        guard status == .recording, !isTranscribing else { return }
        isTranscribing = true  // the same guard as stopRecordingAndTranscribe, so a stop and a cancel can't overlap
        defer { isTranscribing = false }

        hotkeyMonitor.cancelActiveChord()
        overlay.dismiss()
        soundEffects.playStop()
        earlyStart?.transcript.cancel()
        earlyStart = nil
        let transcriptionSession = activeRecordingTranscriptionSession
        _ = await audioRecorder.stopRecording()
        clearRecordingSessionCoordinator()
        transcriptionSession?.cancel()
        recordingOCRPrefetch.cancel()
        textCleanupManager.cancelPromptPrefill()
        mediaPlaybackController.resumeIfPaused()
        isRecording = false
        status = .ready
        activePerformanceTrace = nil
        activeCleanupAttempted = false
        releasePipeline(owner: .liveRecording)
        debugLogStore.record(category: .hotkey, message: "Recording cancelled.")
    }

    /// A click on the indicator: finish and paste, the same as pressing Fn in hands-free mode.
    func finishRecording() async {
        guard status == .recording else { return }
        hotkeyMonitor.cancelActiveChord()
        activePerformanceTrace?.hotkeyLiftedAt = Date()
        await stopRecordingAndTranscribe()
    }

    private func stopRecordingAndTranscribe() async {
        guard status == .recording, !isTranscribing else { return }
        isTranscribing = true
        defer { isTranscribing = false }

        debugLogStore.record(category: .hotkey, message: "Recording stopped. Starting transcription.")
        let buffer = await audioRecorder.stopRecording()
        // Started at a pause, and nothing but quiet recorded since: its transcript is this recording's.
        let earlyTranscript = earlyStart.flatMap { audioRecorder.lastLoudSample <= $0.samples ? $0.transcript : nil }
        if earlyTranscript == nil, let early = earlyStart?.transcript {
            early.cancel()
            _ = await early.value  // never two Parakeet transcriptions at once (shared decoder)
        }
        earlyStart = nil
        let recordingSessionCoordinator = activeRecordingSessionCoordinator
        let recordingTranscriptionSession = activeRecordingTranscriptionSession
        clearRecordingSessionCoordinator()
        soundEffects.playStop()
        mediaPlaybackController.resumeIfPaused()
        isRecording = false
        status = .transcribing
        overlay.show(message: .transcribing)
        activePerformanceTrace?.transcriptionStartAt = Date()
        let windowContextProvider: WindowContextProvider?
        if frontmostWindowContextEnabled {
            windowContextProvider = { [weak self] in
                await self?.recordingOCRPrefetch.resolve()
            }
        } else {
            windowContextProvider = nil
        }

        let didProduceTranscript = await processRecordingResult(
            audioBuffer: buffer,
            recordingSessionCoordinator: recordingSessionCoordinator,
            recordingTranscriptionSession: recordingTranscriptionSession,
            archivedWindowContext: nil,
            windowContextProvider: windowContextProvider,
            shouldPaste: true,
            shouldRecordDebugSnapshot: true,
            earlyTranscript: earlyTranscript
        )

        if didProduceTranscript {
            overlay.dismiss(ifShowing: .transcribing)
            overlay.dismiss(ifShowing: .cleaningUp)
        } else {
            switch Self.emptyTranscriptionDisposition(forAudioSampleCount: buffer.count) {
            case .cancel:
                overlay.dismiss()
                debugLogStore.record(category: .model, message: "Empty transcription cancelled after a short recording.")
            case .showNoSoundDetected:
                overlay.show(message: .noSoundDetected)
                debugLogStore.record(category: .model, message: "No sound detected. Check the microphone in Settings → General.")
            }
            completeActivePerformanceTraceIfNeeded()
        }

        status = .ready
        releasePipeline(owner: .liveRecording)
    }

    func finishRecordingForTesting(
        audioBuffer: [Float],
        recordingSessionCoordinator: RecordingSessionCoordinator?,
        recordingTranscriptionSession: RecordingTranscriptionSession? = nil,
        archivedWindowContext: OCRContext?,
        windowContextProvider: WindowContextProvider? = nil
    ) async {
        _ = await processRecordingResult(
            audioBuffer: audioBuffer,
            recordingSessionCoordinator: recordingSessionCoordinator,
            recordingTranscriptionSession: recordingTranscriptionSession,
            archivedWindowContext: archivedWindowContext,
            windowContextProvider: windowContextProvider,
            shouldPaste: false,
            shouldRecordDebugSnapshot: false
        )
    }

    private func processRecordingResult(
        audioBuffer: [Float],
        recordingSessionCoordinator: RecordingSessionCoordinator?,
        recordingTranscriptionSession: RecordingTranscriptionSession?,
        archivedWindowContext: OCRContext?,
        windowContextProvider: WindowContextProvider?,
        shouldPaste: Bool,
        shouldRecordDebugSnapshot: Bool,
        earlyTranscript: Task<String?, Never>? = nil
    ) async -> Bool {
        let transcriptionResult: RecordingTranscriptionResult
        if let earlyTranscript, let text = await earlyTranscript.value {
            recordingTranscriptionSession?.cancel()
            transcriptionResult = RecordingTranscriptionResult(
                rawTranscription: text,
                speakerFilteringRan: false,
                diarizationSummary: nil
            )
        } else {
            transcriptionResult = await transcribedTextForRecording(
                audioBuffer,
                recordingSessionCoordinator: recordingSessionCoordinator,
                recordingTranscriptionSession: recordingTranscriptionSession
            )
        }

        guard let text = transcriptionResult.rawTranscription else {
            recordingOCRPrefetch.cancel()
            activePerformanceTrace?.transcriptionEndAt = Date()
            return false
        }

        activePerformanceTrace?.transcriptionEndAt = Date()
        var windowContext = archivedWindowContext
        if cleanupEnabled && canAttemptCleanup {
            activeCleanupAttempted = true
            if frontmostWindowContextEnabled,
               windowContext == nil,
               let resolvedWindowContext = await windowContextProvider?() {
                windowContext = resolvedWindowContext.context
                activePerformanceTrace?.ocrCaptureDuration = resolvedWindowContext.elapsed
            }
            activePerformanceTrace?.cleanupStartAt = Date()
            status = .cleaningUp
            if shouldPaste {
                overlay.show(message: .cleaningUp)
            }
            if frontmostWindowContextEnabled, windowContext == nil {
                debugLogStore.record(category: .ocr, message: "No frontmost-window OCR context was captured.")
            }
        } else {
            recordingOCRPrefetch.cancel()
        }

        let cleanupResult = await cleanedTranscriptionResult(text, windowContext: windowContext)
        let finalText = cleanupResult.text
        activeCleanupAttempted = cleanupResult.attemptedCleanup
        if cleanupResult.attemptedCleanup {
            activePerformanceTrace?.cleanupEndAt = Date()
        }

        if shouldRecordDebugSnapshot {
            recordCleanupDebugSnapshot(
                rawTranscription: text,
                windowContext: windowContext,
                cleanedOutput: finalText,
                attemptedCleanup: cleanupResult.attemptedCleanup
            )
        }

        if shouldPaste {
            // snippets, the style and the History page
            let pastedText = HubStore.shared.finish(finalText, raw: text)
            let pasteResult = textPaster.paste(text: pastedText)
            if pasteResult == .copiedToClipboard {
                showClipboardFallbackMessage()
            }
        }

        return true
    }

    private func transcribedTextForRecording(
        _ audioBuffer: [Float],
        recordingSessionCoordinator: RecordingSessionCoordinator?,
        recordingTranscriptionSession: RecordingTranscriptionSession?
    ) async -> RecordingTranscriptionResult {
        let diarizationTask = recordingSessionCoordinator.map { coordinator in
            Task {
                await coordinator.finishResult()
            }
        }
        let concurrentRecordingTranscriptionSession: RecordingTranscriptionSession?
        if let recordingTranscriptionSession,
           recordingTranscriptionSession.supportsConcurrentFinalization {
            concurrentRecordingTranscriptionSession = recordingTranscriptionSession
        } else {
            concurrentRecordingTranscriptionSession = nil
        }

        let streamedTranscriptTask = concurrentRecordingTranscriptionSession.map { session in
            Task<String?, Never> {
                await session.finishTranscription()?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        var diarizationSummary: DiarizationSummary?
        if let diarizationTask {
            let diarizationResult = await diarizationTask.value
            diarizationSummary = diarizationResult.summary

            if diarizationResult.summary.usedFallback == false,
               let filteredTranscript = diarizationResult.filteredTranscript?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               filteredTranscript.isEmpty == false {
                recordingTranscriptionSession?.cancel()
                return RecordingTranscriptionResult(
                    rawTranscription: filteredTranscript,
                    speakerFilteringRan: true,
                    diarizationSummary: diarizationResult.summary
                )
            }
        }

        if let streamedTranscriptTask,
           let streamedTranscript = await streamedTranscriptTask.value,
           streamedTranscript.isEmpty == false {
            return RecordingTranscriptionResult(
                rawTranscription: streamedTranscript,
                speakerFilteringRan: recordingSessionCoordinator != nil,
                diarizationSummary: diarizationSummary
            )
        }

        if concurrentRecordingTranscriptionSession == nil,
           let recordingTranscriptionSession,
           let streamedTranscript = await recordingTranscriptionSession.finishTranscription()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           streamedTranscript.isEmpty == false {
            return RecordingTranscriptionResult(
                rawTranscription: streamedTranscript,
                speakerFilteringRan: recordingSessionCoordinator != nil,
                diarizationSummary: diarizationSummary
            )
        }

        if let recordingTranscriptionSession,
           recordingTranscriptionSession.allowsBatchFallback == false {
            return RecordingTranscriptionResult(
                rawTranscription: nil,
                speakerFilteringRan: recordingSessionCoordinator != nil,
                diarizationSummary: diarizationSummary
            )
        }

        return RecordingTranscriptionResult(
            rawTranscription: await transcribeAudioBuffer(audioBuffer),
            speakerFilteringRan: recordingSessionCoordinator != nil,
            diarizationSummary: diarizationSummary
        )
    }

    private func transcribeAudioBuffer(_ audioBuffer: [Float]) async -> String? {
        if let transcribeAudioBufferOverride {
            return transcribeAudioBufferOverride(audioBuffer)
        }

        let language = preferredLanguage == "auto" ? nil : preferredLanguage
        return await transcriber.transcribe(audioBuffer: audioBuffer, language: language)
    }

    func cleanedTranscription(_ text: String) async -> String {
        let result = await cleanedTranscriptionResult(text, windowContext: nil)
        return result.text
    }

    private func showClipboardFallbackMessage() {
        overlay.show(message: .clipboardFallback(
            appName: textPaster.lastPasteTargetApplication?.displayName
        ))
    }

    func removeAlwaysAllowedPasteApplication(bundleIdentifier: String) {
        alwaysAllowedPasteApplications.removeAll { $0.bundleIdentifier == bundleIdentifier }
        persistAlwaysAllowedPasteApplications()
    }

    private func alwaysAllowLastPasteTarget() {
        guard let application = textPaster.lastPasteTargetApplication else { return }
        if !alwaysAllowedPasteApplications.contains(where: {
            $0.bundleIdentifier == application.bundleIdentifier
        }) {
            alwaysAllowedPasteApplications.append(application)
            alwaysAllowedPasteApplications.sort {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            persistAlwaysAllowedPasteApplications()
        }
        _ = textPaster.retryLastClipboardPaste()
        overlay.dismiss()
    }

    private func persistAlwaysAllowedPasteApplications() {
        guard let data = try? JSONEncoder().encode(alwaysAllowedPasteApplications) else { return }
        cleanupSettingsDefaults.set(data, forKey: Self.alwaysAllowedPasteApplicationsDefaultsKey)
    }

    private static func loadAlwaysAllowedPasteApplications(
        defaults: UserDefaults
    ) -> [PasteTargetApplication] {
        guard let data = defaults.data(forKey: alwaysAllowedPasteApplicationsDefaultsKey),
              let applications = try? JSONDecoder().decode([PasteTargetApplication].self, from: data) else {
            return []
        }
        return applications
    }

    private let hubController = HubWindowController()
    private let meetingDetector = MeetingDetector()
    @Published var activeMeetingSession: MeetingSession? {
        didSet {
            if let activeMeetingSession { overlay.showNotetaker(activeMeetingSession) } else { overlay.hideNotetaker() }
        }
    }

    var canReloadAudioInput: Bool {
        Self.isLiveRecordingNoInputError(errorMessage)
    }

    func resetAudioEngine() {
        audioRecorder.targetDeviceID = selectedInputDeviceIDProvider()
        resetAudioRecorder()

        if shouldClearLiveRecordingNoInputErrorAfterAudioReset {
            errorMessage = nil
            status = .ready
            debugLogStore.record(category: .model, message: "Audio engine reset cleared stale no-input recording error.")
        }

        debugLogStore.record(category: .model, message: "Audio engine reset for device change.")
    }

    func showHub() {
        hubController.show(appState: self)
    }

    func showSettings() {
        SettingsWindowController.shared.show(appState: self)
    }

    // MARK: - Meeting Transcript

    /// Creates a new MeetingSession, starts recording, and returns it.
    /// Called by the window state when the user clicks "+" or auto-detection triggers.
    func createMeetingSession(name: String, detectedMeeting: DetectedMeeting? = nil) throws -> MeetingSession {
        guard canStartSpeechAnalyzerConsumer else {
            let message = "Meeting recording is still getting the speech model ready. Wait a moment, then click Start recording again."
            debugLogStore.record(category: .model, message: "Meeting transcription start skipped because the SpeechAnalyzer model is loading.")
            throw MeetingRecordingStartError.unavailable(message)
        }
        let saveDir = MeetingTranscriptSettings.effectiveSaveDirectory()
        let session = MeetingSession(
            meetingName: name,
            detectedMeeting: detectedMeeting,
            transcriber: transcriber,
            saveDirectory: saveDir,
            remoteSpeakerTagger: { [weak self] _, audioBuffer in
                await self?.remoteSpeakerTaggedTranscript(audioBuffer: audioBuffer)
            }
        )
        session.onAutoStopRequested = { [weak self] session in
            Task {
                await self?.finishMeetingSession(session, logPrefix: "Meeting transcription auto-stopped")
            }
        }
        activeMeetingSession = session

        pendingMeetingSessionStarts += 1
        Task { @MainActor in
            defer {
                if pendingMeetingSessionStarts > 0 {
                    pendingMeetingSessionStarts -= 1
                }
            }
            do {
                try await session.start()
                guard session.isActive else {
                    if activeMeetingSession === session {
                        activeMeetingSession = nil
                    }
                    return
                }
                // Count the attempt — usage-report semantics value "how often
                // does the user try to use this?" over "did the file save."
                // Captures abandoned/cancelled recordings too.
                debugLogStore.record(category: .model, message: "Meeting transcription started: \(name)")
            } catch {
                await session.stop()
                debugLogStore.record(category: .model, message: "Meeting transcription failed to start: \(error.localizedDescription)")
                if activeMeetingSession === session {
                    activeMeetingSession = nil
                }
            }
        }

        return session
    }

    func startMeetingTranscription(meetingName: String, detectedMeeting: DetectedMeeting? = nil) {
        guard activeMeetingSession == nil else { return }
        do {
            _ = try createMeetingSession(name: meetingName, detectedMeeting: detectedMeeting)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopMeetingTranscription() {
        guard let session = activeMeetingSession else { return }
        Task {
            await finishMeetingSession(session, logPrefix: "Meeting transcription stopped")
        }
    }

    func setupMeetingDetector() {
        guard meetingTranscriptEnabled, meetingAutoDetectEnabled else {
            meetingDetector.stop()
            return
        }

        meetingDetector.onMeetingDetected = { [weak self] meeting in
            guard let self = self, self.activeMeetingSession == nil else { return }
            self.meetingPrompt.show(meetingName: meeting.suggestedName) { [weak self] in
                guard let self, self.activeMeetingSession == nil else { return }
                self.startMeetingTranscription(meetingName: meeting.suggestedName, detectedMeeting: meeting)
            }
        }

        meetingDetector.start()
    }

    private func finishMeetingSession(_ session: MeetingSession, logPrefix: String) async {
        await session.stop()
        if activeMeetingSession === session {
            activeMeetingSession = nil
        }
        debugLogStore.record(category: .model, message: "\(logPrefix): \(session.transcript.meetingName)")
    }

    /// Diarized transcript of the other side of the call, speakers named "Speaker 1", "Speaker 2", ...
    private func remoteSpeakerTaggedTranscript(audioBuffer: [Float]) async -> SpeakerTaggedTranscript? {
        guard let tagged = await modelManager.transcribeWithSpeakerTagging(audioBuffer: audioBuffer)?.speakerTaggedTranscript else {
            return nil
        }
        let names = Self.fallbackSpeakerDisplayNames(for: tagged)
        return SpeakerTaggedTranscript(segments: tagged.segments.map { segment in
            SpeakerTaggedTranscript.Segment(
                speakerID: segment.speakerID,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text,
                attribution: SpeakerTaggedTranscript.Attribution(
                    speakerID: segment.speakerID,
                    displayName: names[segment.speakerID],
                    confidence: segment.attribution.confidence,
                    evidenceDuration: segment.attribution.evidenceDuration,
                    source: segment.attribution.source
                )
            )
        })
    }

    private static func fallbackSpeakerDisplayNames(
        for speakerTaggedTranscript: SpeakerTaggedTranscript
    ) -> [String: String] {
        var orderedSpeakerIDs: [String] = []
        for segment in speakerTaggedTranscript.segments where !orderedSpeakerIDs.contains(segment.speakerID) {
            orderedSpeakerIDs.append(segment.speakerID)
        }

        return Dictionary(
            uniqueKeysWithValues: orderedSpeakerIDs.enumerated().map { offset, speakerID in
                (speakerID, "Speaker \(offset + 1)")
            }
        )
    }

    private var shortcutBindings: [ChordAction: KeyChord] {
        [.pushToTalk: pushToTalkChord, .toggleToTalk: toggleToTalkChord]
    }

    private func persistShortcutBindingsIfNeeded() {
        try? chordBindingStore.setBinding(pushToTalkChord, for: .pushToTalk)
        try? chordBindingStore.setBinding(toggleToTalkChord, for: .toggleToTalk)
    }

    private var canAttemptCleanup: Bool {
        textCleanupManager.isReady
    }

    var shouldLoadLocalCleanupModels: Bool {
        cleanupEnabled
    }

    private func cleanedTranscriptionResult(
        _ text: String,
        windowContext: OCRContext?
    ) async -> CleanupResult {
        if let cleanedTranscriptionResultOverride {
            return await cleanedTranscriptionResultOverride(text, windowContext)
        }

        guard cleanupEnabled else {
            return (text: text, prompt: cleanupPrompt, attemptedCleanup: false, cleanupUsedFallback: false)
        }

        let activeCleanupPrompt: String
        if canAttemptCleanup {
            let promptBuildStart = Date()
            activeCleanupPrompt = activeCleanupPromptComponents(windowContext: windowContext).fullPrompt
            activePerformanceTrace?.promptBuildDuration = Date().timeIntervalSince(promptBuildStart)
        } else {
            activeCleanupPrompt = languageAwareCleanupPrompt
        }

        let cleanedResult = await textCleaner.cleanWithPerformance(
            text: text,
            prompt: activeCleanupPrompt,
            modelKind: textCleanupManager.selectedCleanupModelKind
        )
        activePerformanceTrace?.modelCallDuration = cleanedResult.performance.modelCallDuration
        activePerformanceTrace?.postProcessDuration = cleanedResult.performance.postProcessDuration
        return (
            text: cleanedResult.text,
            prompt: activeCleanupPrompt,
            attemptedCleanup: canAttemptCleanup,
            cleanupUsedFallback: cleanedResult.usedFallback
        )
    }

    private var languageAwareCleanupPrompt: String {
        if preferredLanguage != "auto" && preferredLanguage != "en" {
            let langName = Locale.current.localizedString(forLanguageCode: preferredLanguage) ?? preferredLanguage
            return cleanupPrompt + "\n\nThe transcription is in \(langName). Preserve the original language — do not translate to English."
        }

        return cleanupPrompt
    }

    private func activeCleanupPromptComponents(windowContext: OCRContext?) -> CleanupPromptComponents {
        cleanupPromptBuilder.buildPromptComponents(
            basePrompt: languageAwareCleanupPrompt,
            windowContext: windowContext,
            preferredTranscriptions: correctionStore.preferredTranscriptions,
            commonlyMisheard: correctionStore.commonlyMisheard,
            includeWindowContext: frontmostWindowContextEnabled
        )
    }

    var ocrCustomWords: [String] {
        correctionStore.preferredOCRCustomWords
    }

    func recordCleanupDebugSnapshot(
        rawTranscription: String,
        windowContext: OCRContext?,
        cleanedOutput: String,
        attemptedCleanup: Bool
    ) {
        debugLogStore.recordSensitive(
            category: .cleanup,
            message: """
            Raw transcription:
            \(rawTranscription)
            """
        )
        debugLogStore.recordSensitive(
            category: .cleanup,
            message: "cleanupEnabled=\(cleanupEnabled) attemptedCleanup=\(attemptedCleanup) backend=\(cleanupBackend.rawValue)"
        )
        let windowContextSummary = windowContext?.windowContents.isEmpty == false ? "captured" : "none"
        debugLogStore.recordSensitive(
            category: .cleanup,
            message: "Cleanup context summary: windowContext=\(windowContextSummary)"
        )
        debugLogStore.recordSensitive(
            category: .cleanup,
            message: "Final cleaned output:\n\(cleanedOutput)"
        )
    }

    private func beginPerformanceTrace() {
        var trace = PerformanceTrace(sessionID: UUID().uuidString)
        trace.hotkeyDetectedAt = Date()
        activePerformanceTrace = trace
        activeCleanupAttempted = false
    }

    private func completeActivePerformanceTraceIfNeeded() {
        guard var trace = activePerformanceTrace else {
            return
        }

        if trace.pasteEndAt == nil {
            trace.pasteEndAt = Date()
        }

        debugLogStore.record(
            category: .performance,
            message: trace.summary(
                speechModelID: speechModel,
                cleanupBackend: cleanupBackend,
                cleanupAttempted: activeCleanupAttempted
            )
        )

        activePerformanceTrace = nil
        activeCleanupAttempted = false
        recordingOCRPrefetch.cancel()
    }

    func updateShortcut(_ chord: KeyChord, for action: ChordAction) {
        let previousPushChord = pushToTalkChord
        let previousToggleChord = toggleToTalkChord

        do {
            try chordBindingStore.setBinding(chord, for: action)
            shortcutErrorMessage = nil

            switch action {
            case .pushToTalk:
                pushToTalkChord = chord
            case .toggleToTalk:
                toggleToTalkChord = chord
            }

            hotkeyMonitor.updateBindings(shortcutBindings)
        } catch {
            pushToTalkChord = previousPushChord
            toggleToTalkChord = previousToggleChord
            shortcutErrorMessage = "That shortcut is already in use."
        }
    }

    func setShortcutCaptureActive(_ isActive: Bool) {
        hotkeyMonitor.setSuspended(isActive)
    }

    func setCleanupEnabled(_ enabled: Bool) {
        cleanupEnabled = enabled
        Task {
            await refreshCleanupModelState()
        }
    }

    func updateCleanupBackend(_ backend: CleanupBackendOption) {
        cleanupBackend = backend
        Task {
            await refreshCleanupModelState()
        }
    }

    func prepareForTermination() {
        recordingOCRPrefetch.cancel()
        textCleanupManager.shutdownBackend()
        meetingDetector.stop()
        if let session = activeMeetingSession {
            Task { await session.stop() }
        }
    }

    func acquirePipeline(for owner: PipelineOwner) -> Bool {
        guard pipelineOwner == nil else {
            return false
        }

        pipelineOwner = owner
        return true
    }

    func releasePipeline(owner: PipelineOwner) {
        guard pipelineOwner == owner else {
            return
        }

        pipelineOwner = nil
    }

    private func refreshCleanupModelState() async {
        guard cleanupEnabled else {
            debugLogStore.record(category: .model, message: "Cleanup disabled; unloading local cleanup models.")
            textCleanupManager.unloadModel()
            objectWillChange.send()
            return
        }

        let shouldLoadLocalModels = shouldLoadLocalCleanupModels
        debugLogStore.record(
            category: .model,
            message: "Cleanup backend is \(cleanupBackend.rawValue). shouldLoadLocalModels=\(shouldLoadLocalModels)"
        )

        if shouldLoadLocalModels {
            await textCleanupManager.loadModel()
        } else {
            textCleanupManager.unloadModel()
        }

        objectWillChange.send()
    }

    func loadSpeechModel(name: String) async {
        let language = preferredLanguage == "auto" ? nil : preferredLanguage
        await modelManager.loadModel(name: name, language: language)
        let nextPresentation = Self.nextSpeechModelPresentation(
            managerState: modelManager.state,
            managerError: modelManager.error,
            currentStatus: status,
            currentErrorMessage: errorMessage
        )
        status = nextPresentation.status
        errorMessage = nextPresentation.errorMessage
    }

    func reloadSpeechAnalyzerForPreferredLanguageIfNeeded() async {
        guard SpeechModelCatalog.model(named: speechModel)?.backend == .speechAnalyzer else {
            return
        }

        speechAnalyzerReloadsInFlight += 1
        let reloadGeneration = speechAnalyzerReloadsInFlight
        defer {
            speechAnalyzerReloadsInFlight = max(speechAnalyzerReloadsInFlight - 1, 0)
            if speechAnalyzerReloadsInFlight == 0,
               reloadGeneration > 0,
               !isSpeechAnalyzerSessionActive,
               status == .loading,
               modelManager.isReady {
                status = .ready
            }
        }

        await waitForSpeechAnalyzerSessionToBecomeIdle()
        guard !Task.isCancelled else { return }

        if status == .ready, !isSpeechAnalyzerSessionActive {
            status = .loading
        }

        while modelManager.state == .loading {
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(nanoseconds: Self.speechAnalyzerReloadPollIntervalNanoseconds)
            } catch {
                return
            }
        }

        guard !Task.isCancelled else { return }
        await loadSpeechModel(name: speechModel)
        if speechAnalyzerReloadsInFlight > 1, !Task.isCancelled {
            status = .loading
        }
    }

    private var isSpeechAnalyzerSessionActive: Bool {
        isRecording
            || isTranscribing
            || status == .recording
            || status == .transcribing
            || pipelineOwner != nil
            || pendingMeetingSessionStarts > 0
            || activeMeetingSession?.isStarting == true
            || activeMeetingSession?.isActive == true
            || activeMeetingSession?.isDraining == true
    }

    private func waitForSpeechAnalyzerSessionToBecomeIdle() async {
        while isSpeechAnalyzerSessionActive {
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(nanoseconds: Self.speechAnalyzerReloadPollIntervalNanoseconds)
            } catch {
                return
            }
        }
    }

    static func nextSpeechModelPresentation(
        managerState: ModelManagerState,
        managerError: Error?,
        currentStatus: AppStatus,
        currentErrorMessage: String?
    ) -> (status: AppStatus, errorMessage: String?) {
        switch managerState {
        case .error:
            let shouldClearSpeechModelError = currentErrorMessage?.hasPrefix(speechModelErrorPrefix) == true
            let preservedErrorMessage = shouldClearSpeechModelError ? nil : currentErrorMessage
            return (
                .error,
                preservedErrorMessage
            )
        case .ready:
            let shouldClearSpeechModelError = currentErrorMessage?.hasPrefix(speechModelErrorPrefix) == true
            let nextStatus: AppStatus
            if currentStatus == .loading {
                nextStatus = .ready
            } else if shouldClearSpeechModelError && currentStatus == .error {
                nextStatus = .ready
            } else {
                nextStatus = currentStatus
            }
            return (
                nextStatus,
                shouldClearSpeechModelError ? nil : currentErrorMessage
            )
        case .idle, .loading:
            return (currentStatus, currentErrorMessage)
        }
    }

    private var shouldClearLiveRecordingNoInputErrorAfterAudioReset: Bool {
        status == .error && !isRecording && !isTranscribing && Self.isLiveRecordingNoInputError(errorMessage)
    }

    private static func isLiveRecordingNoInputError(_ message: String?) -> Bool {
        message == liveRecordingNoInputErrorMessage
    }
}
