import AppKit
import CoreAudio
import ServiceManagement
import SwiftUI

// Settings: a plain macOS window with standard controls, apart from the blue canvas.

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(appState: AppState) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 660),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Diction Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(appState: appState))
            w.center()
            w.setFrameAutosaveName("DictionSettings")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var devices: [AudioInputDevice]
    @State private var deviceID: AudioDeviceID
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("showInDock") private var showInDock = true
    @State private var apiKey = ""
    @State private var keySaved = AnthropicCleanupBackend.hasAPIKey
    @State private var keyFailed = false

    /// The microphone is read here, not on appear: setting it there counts as a change and restarted the audio engine.
    init(appState: AppState) {
        self.appState = appState
        let devices = AudioDeviceManager.listInputDevices()
        _devices = State(initialValue: devices)
        _deviceID = State(initialValue: AudioDeviceManager.preferredInputDeviceID(inputDevices: { devices }) ?? 0)
    }

    var body: some View {
        Form {
            Section("Dictation") {
                ShortcutRecorderView(title: "Hold to talk", chord: appState.pushToTalkChord,
                                     onRecordingStateChange: appState.setShortcutCaptureActive) { appState.updateShortcut($0, for: .pushToTalk) }
                ShortcutRecorderView(title: "Hands-free", chord: appState.toggleToTalkChord,
                                     onRecordingStateChange: appState.setShortcutCaptureActive) { appState.updateShortcut($0, for: .toggleToTalk) }
                if let error = appState.shortcutErrorMessage { Text(error).foregroundStyle(.red) }
                Picker("Microphone", selection: $deviceID) {
                    ForEach(devices) { Text($0.name).tag($0.id) }
                }
                .onChange(of: deviceID) { _, id in
                    AudioDeviceManager.setSelectedInputDevice(id)
                    appState.resetAudioEngine()
                }
                Picker("Language", selection: $appState.preferredLanguage) {
                    Text("Detect automatically").tag("auto")
                    Text("English").tag("en")
                    Text("German").tag("de")
                    Text("Spanish").tag("es")
                    Text("French").tag("fr")
                    Text("Italian").tag("it")
                }
                .onChange(of: appState.preferredLanguage) { _, _ in
                    Task { await appState.reloadSpeechAnalyzerForPreferredLanguageIfNeeded() }
                }
                Toggle("Sounds", isOn: Binding(get: { appState.playSounds }, set: { appState.playSounds = $0 }))
                Toggle("Pause music and video while dictating", isOn: $appState.pauseMediaWhileRecording)
            }

            Section {
                HStack {
                    SecureField("Anthropic API key", text: $apiKey, prompt: Text(keySaved ? "Saved in your Keychain" : "sk-ant-…"))
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey)
                }
                if keyFailed { Text("The Keychain didn't accept the key. Try again.").foregroundStyle(.red) }
                Picker("Speech model", selection: Binding(get: { appState.speechModel }, set: { name in
                    appState.speechModel = name
                    Task { await appState.loadSpeechModel(name: name) }
                })) {
                    ForEach(SpeechModelCatalog.availableModels) { Text("\($0.pickerTitle), \($0.variantName)").tag($0.name) }
                }
                Toggle("Read the window you dictate into", isOn: $appState.frontmostWindowContextEnabled)
                Toggle("Learn from my corrections", isOn: $appState.postPasteLearningEnabled)
            } header: {
                Text("Cleanup")
            } footer: {
                Text("With an Anthropic API key, Claude Haiku cleans up each dictation. Without one, a small model on this Mac does it. "
                     + "Reading the window helps with names; learning adds the words you fix after pasting to your dictionary.")
            }

            Section {
                Toggle("Notes", isOn: $appState.meetingTranscriptEnabled)
                    .onChange(of: appState.meetingTranscriptEnabled) { _, _ in appState.setupMeetingDetector() }
                Toggle("Offer notes when a call starts", isOn: $appState.meetingAutoDetectEnabled)
                    .onChange(of: appState.meetingAutoDetectEnabled) { _, _ in appState.setupMeetingDetector() }
            } header: {
                Text("Meetings")
            } footer: {
                Text("Diction records and transcribes meetings on this Mac. It needs Screen Recording to hear the other side of a call.")
            }

            Section("App") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch { launchAtLogin = !on }
                    }
                Toggle("Show in Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, _ in
                        HubWindowController.applyDockPolicy()
                        NSApp.activate(ignoringOtherApps: true)
                    }
                LabeledContent("Logs") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([DebugLogStore.defaultStorageURL]) }
                }
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            }
        }
        .formStyle(.grouped)
    }

    private func saveKey() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keyFailed = !AnthropicCleanupBackend.saveAPIKey(key)
        if !keyFailed {
            keySaved = true
            apiKey = ""
        }
    }
}
