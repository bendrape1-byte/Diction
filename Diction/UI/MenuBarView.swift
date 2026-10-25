import SwiftUI
import CoreAudio

/// The menu bar menu: open the window, paste the last transcript, microphone, settings, quit.
struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var store = HubStore.shared

    var body: some View {
        Button("Open Diction") { appState.showHub() }

        Button("Paste last transcript") {
            if let last = store.dictations.first { _ = appState.textPaster.paste(text: last.text) }
        }
        .disabled(store.dictations.isEmpty)

        Menu("Microphone") {
            let selected = AudioDeviceManager.selectedInputDeviceUID()
            ForEach(AudioDeviceManager.listInputDevices()) { device in
                Toggle(device.name, isOn: Binding(
                    get: { device.uid == selected },
                    set: { _ in
                        AudioDeviceManager.setSelectedInputDevice(device.id)
                        appState.resetAudioEngine()
                    }
                ))
            }
        }

        if appState.activeMeetingSession != nil {
            Button("Stop notes") { appState.stopMeetingTranscription() }
        }

        if let status = statusLine {
            Divider()
            Text(status)
        }

        if let error = appState.errorMessage {
            Divider()
            Text(error)
            if appState.canReloadAudioInput {
                Button("Reload audio input") { appState.resetAudioEngine() }
            }
            if error.contains("Input Monitoring") || error.contains("Accessibility") || error.contains("Microphone") {
                Button("Fix permissions…") { appState.showPermissions() }
            }
        }

        Divider()

        Button("Settings…") { appState.showSettings() }
            .keyboardShortcut(",")

        Button("Quit Diction") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String? {
        switch appState.status {
        case .loading: "Loading speech model…"
        case .recording: "Listening…"
        case .transcribing, .cleaningUp: "Transcribing…"
        case .ready, .error: nil
        }
    }
}
