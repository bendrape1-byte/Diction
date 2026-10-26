import AppKit
import CoreAudio
import ServiceManagement
import SwiftUI

// Settings, on the same blue canvas as the main window: rows split by thin rules, white switches,
// and menus that show only their value.

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(appState: AppState) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Diction Settings"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.appearance = NSAppearance(named: .darkAqua)  // light cursors, scroll bars and menus on the blue
            w.backgroundColor = NSColor(D.blue)
            w.minSize = NSSize(width: 460, height: 420)
            w.isReleasedWhenClosed = false
            // Same as the first-run window: the window keeps its size instead of growing to fit wrapped text.
            let hosting = NSHostingView(rootView: SettingsView(appState: appState))
            hosting.sizingOptions = []
            w.contentView = hosting
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
    @AppStorage(AnthropicCleanupBackend.localOnlyDefaultsKey) private var localOnly = false
    @State private var apiKey = ""
    @State private var keySaved = AnthropicCleanupBackend.hasAPIKey
    @State private var keyFailed = false

    private static let languages: [(value: String, title: String)] = [
        ("auto", "Detect automatically"), ("en", "English"), ("de", "German"),
        ("es", "Spanish"), ("fr", "French"), ("it", "Italian"),
    ]

    /// The microphone is read here, not on appear: setting it there counts as a change and restarted the audio engine.
    init(appState: AppState) {
        self.appState = appState
        let devices = AudioDeviceManager.listInputDevices()
        _devices = State(initialValue: devices)
        _deviceID = State(initialValue: AudioDeviceManager.preferredInputDeviceID(inputDevices: { devices }) ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Settings")
                .font(D.font(13.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 90)  // right of the traffic lights, where the main window has its tabs
                .frame(height: 30)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    dictation
                    cleanup
                    meetings
                    app
                }
                .padding(.horizontal, 32)
                .padding(.top, 18)
                .padding(.bottom, 32)
            }
        }
        .background(D.blue)
        .foregroundStyle(.white)
        .font(D.font(14.5))
        .tint(.white)
        .ignoresSafeArea()
        .onChange(of: deviceID) { _, id in
            AudioDeviceManager.setSelectedInputDevice(id)
            appState.resetAudioEngine()
        }
        .onChange(of: appState.preferredLanguage) { _, _ in
            Task { await appState.reloadSpeechAnalyzerForPreferredLanguageIfNeeded() }
        }
    }

    private var dictation: some View {
        SettingsSection("Dictation") {
            ShortcutRecorderView(title: "Hold to talk", chord: appState.pushToTalkChord,
                                 onRecordingStateChange: appState.setShortcutCaptureActive) { appState.updateShortcut($0, for: .pushToTalk) }
                .settingsRow()
            ShortcutRecorderView(title: "Hands-free", chord: appState.toggleToTalkChord,
                                 onRecordingStateChange: appState.setShortcutCaptureActive) { appState.updateShortcut($0, for: .toggleToTalk) }
                .settingsRow()
            if let error = appState.shortcutErrorMessage {
                Text(error).font(D.font(12.5)).foregroundStyle(D.warn).padding(.top, 8)
            }
            SettingsRow("Microphone") {
                MenuPicker(selection: $deviceID, choices: devices.map { (value: $0.id, title: $0.name) })
            }
            SettingsRow("Language") {
                MenuPicker(selection: $appState.preferredLanguage, choices: Self.languages)
            }
            Toggle("Sounds", isOn: Binding(get: { appState.playSounds }, set: { appState.playSounds = $0 }))
                .toggleStyle(LineSwitchStyle()).settingsRow()
            Toggle("Pause music and video while dictating", isOn: $appState.pauseMediaWhileRecording)
                .toggleStyle(LineSwitchStyle()).settingsRow()
        }
    }

    private var cleanup: some View {
        SettingsSection("Cleanup", footer: "Claude Haiku uses your Anthropic API key, which stays on your Mac, and costs less than 1 cent per 1,000 words. "
                        + "Local only is free and nothing leaves your Mac, but it's noticeably worse. "
                        + "Reading the window helps with names; learning adds the words you fix after pasting to your dictionary.") {
            SettingsRow("Clean up with") {
                MenuPicker(selection: $localOnly, choices: [(value: false, title: "Claude Haiku"), (value: true, title: "Local only")])
            }
            if !localOnly {
                HStack(alignment: .center, spacing: 14) {
                    SecureField("Anthropic API key", text: $apiKey,
                                prompt: Text(keySaved ? "API key saved in your Keychain" : "Anthropic API key, sk-ant-…"))
                        .textFieldStyle(.plain)
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.35)).frame(height: 1) }
                        .onSubmit(saveKey)
                    LineButton(title: "Save", action: saveKey)
                }
                .padding(.vertical, 8)
                if keyFailed {
                    Text("The Keychain didn't accept the key. Try again.").font(D.font(12.5)).foregroundStyle(D.warn)
                }
            }
            SettingsRow("Speech model") {
                MenuPicker(selection: Binding(get: { appState.speechModel }, set: { name in
                    appState.speechModel = name
                    Task { await appState.loadSpeechModel(name: name) }
                }), choices: SpeechModelCatalog.availableModels.map { (value: $0.name, title: "\($0.pickerTitle), \($0.variantName)") })
            }
            Toggle("Read the window you dictate into", isOn: $appState.frontmostWindowContextEnabled)
                .toggleStyle(LineSwitchStyle()).settingsRow()
            Toggle("Learn from my corrections", isOn: $appState.postPasteLearningEnabled)
                .toggleStyle(LineSwitchStyle()).settingsRow()
        }
    }

    private var meetings: some View {
        SettingsSection("Meetings", footer: "Diction records and transcribes meetings on this Mac. It needs Screen Recording to hear the other side of a call.") {
            Toggle("Notes", isOn: $appState.meetingTranscriptEnabled)
                .toggleStyle(LineSwitchStyle()).settingsRow()
                .onChange(of: appState.meetingTranscriptEnabled) { _, _ in appState.setupMeetingDetector() }
            Toggle("Offer notes when a call starts", isOn: $appState.meetingAutoDetectEnabled)
                .toggleStyle(LineSwitchStyle()).settingsRow()
                .onChange(of: appState.meetingAutoDetectEnabled) { _, _ in appState.setupMeetingDetector() }
        }
    }

    private var app: some View {
        SettingsSection("App") {
            Toggle("Open at login", isOn: $launchAtLogin)
                .toggleStyle(LineSwitchStyle()).settingsRow()
                .onChange(of: launchAtLogin) { _, on in
                    do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch { launchAtLogin = !on }
                }
            Toggle("Show in Dock", isOn: $showInDock)
                .toggleStyle(LineSwitchStyle()).settingsRow()
                .onChange(of: showInDock) { _, _ in
                    HubWindowController.applyDockPolicy()
                    NSApp.activate(ignoringOtherApps: true)
                }
            SettingsRow("Logs") {
                LineButton(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([DebugLogStore.defaultStorageURL]) }
            }
            SettingsRow("Version") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "").foregroundStyle(D.ink2)
            }
        }
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

// MARK: - pieces

/// A bold heading, its rows, and an optional note under them.
private struct SettingsSection<Content: View>: View {
    let title: String
    let footer: String?
    let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(D.font(14, .bold)).padding(.bottom, 4)
            content
            if let footer {
                Text(footer)
                    .font(D.font(12.5)).foregroundStyle(D.ink3).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
        }
        .padding(.bottom, 34)
    }
}

/// A label on the left, its control on the right.
private struct SettingsRow<Control: View>: View {
    let title: String
    let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
            Spacer(minLength: 12)
            control
        }
        .settingsRow()
    }
}

private extension View {
    /// The space around a row and the thin rule under it.
    func settingsRow() -> some View {
        padding(.vertical, 11)
            .frame(minHeight: 44)
            .overlay(alignment: .bottom) { Rectangle().fill(D.rule).frame(height: 1) }
    }
}

/// A switch drawn like the window's buttons: a white outline that fills white when on.
struct LineSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.timingCurve(0.25, 1, 0.5, 1, duration: 0.22)) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: 16) {
                configuration.label
                Spacer(minLength: 12)
                Capsule()
                    .fill(configuration.isOn ? Color.white : .clear)
                    .overlay(Capsule().strokeBorder(configuration.isOn ? Color.white : D.ink4, lineWidth: 1))
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(configuration.isOn ? D.blue : D.ink3).frame(width: 12, height: 12).padding(3)
                    }
                    .frame(width: 34, height: 18)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

/// A pop-up menu that shows only its current value and a small chevron, in the window's type.
struct MenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let choices: [(value: Value, title: String)]

    var body: some View {
        Menu {
            ForEach(choices.indices, id: \.self) { i in
                Toggle(choices[i].title, isOn: Binding(get: { choices[i].value == selection },
                                                       set: { if $0 { selection = choices[i].value } }))
            }
        } label: {
            HStack(spacing: 6) {
                Text(choices.first { $0.value == selection }?.title ?? "None").lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(D.ink3)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
