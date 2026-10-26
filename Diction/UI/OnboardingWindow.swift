import AppKit
import SwiftUI

// First-run setup on the blue canvas: welcome → cleanup → permissions → try it.
// Also opens straight at permissions when one goes missing later.

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    func show(appState: AppState, startAtPermissions: Bool, onFinish: @escaping () -> Void) {
        window?.close()
        NSApp.setActivationPolicy(.regular)
        let view = OnboardingView(appState: appState, step: startAtPermissions ? .permissions : .welcome) { [weak self] in
            self?.window?.close()
            self?.window = nil
            onFinish()
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(D.blue)
        w.isReleasedWhenClosed = false
        // The window keeps this size. By default the hosting view sets a minimum size from the layout, and wrapped text
        // measured at zero width came out ~1,900 pt tall, so the window grew past the screen.
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        w.contentView = hosting
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    var isVisible: Bool { window?.isVisible == true }
}

struct OnboardingView: View {
    enum Step { case welcome, cleanup, permissions, tryIt }

    @ObservedObject var appState: AppState
    @State var step: Step
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LineMark().stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 44, height: 22)
                .padding(.top, 52)

            Spacer(minLength: 24)
            switch step {
            case .welcome: welcome
            case .cleanup: CleanupStep { step = .permissions }
            case .permissions: PermissionsStep(appState: appState) { step = .tryIt }
            case .tryIt: TryItStep(appState: appState, onFinish: onFinish)
            }
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 56)
        .padding(.bottom, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(D.blue)
        .foregroundStyle(.white)
        .tint(.white)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Diction").font(D.font(44, .bold))
            Text("Hold \(appState.pushToTalkChord.displayString) and talk. When you let go, the text appears wherever your cursor is, in any app.")
                .font(D.font(16)).foregroundStyle(D.ink2).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 460, alignment: .leading)
            WhiteButton(title: "Set up") { step = .cleanup }.padding(.top, 10)
        }
    }
}

/// Who cleans up each dictation: Claude Haiku with your own API key, or the small model on this Mac.
/// Comes before the permissions, which often end in a restart that skips the rest of the setup.
private struct CleanupStep: View {
    let onContinue: () -> Void
    @State private var apiKey = ""
    @State private var keySaved = AnthropicCleanupBackend.hasAPIKey
    @State private var keyFailed = false

    private var canUseHaiku: Bool { keySaved || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cleanup").font(D.font(32, .bold))
            Text("Filler words out, punctuation in. Choose what does it.")
                .font(D.font(16)).foregroundStyle(D.ink2)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 480, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                haiku
                local
            }
            .frame(maxWidth: 520)
            .padding(.top, 6)
        }
    }

    private var haiku: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Claude Haiku", "Recommended")
            HStack(spacing: 12) {
                SecureField("Anthropic API key", text: $apiKey,
                            prompt: Text(keySaved ? "API key saved in your Keychain" : "Anthropic API key, sk-ant-…"))
                    .textFieldStyle(.plain)
                    .font(D.font(14.5))
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.35)).frame(height: 1) }
                    .onSubmit(useHaiku)
                WhiteButton(title: "Use Haiku", action: useHaiku)
                    .disabled(!canUseHaiku)
                    .opacity(canUseHaiku ? 1 : 0.5)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("This will stay on your Mac. Diction only sends it to Anthropic.")
                Text("Costs less than 1 cent per 1,000 words dictated.")
                if keyFailed {
                    Text("The Keychain didn't accept the key. Try again.").foregroundStyle(D.warn)
                }
                Link(destination: URL(string: "https://platform.claude.com/settings/keys")!) {
                    Text("Get a key at platform.claude.com").underline()
                }
            }
            .font(D.font(13.5))
            .foregroundStyle(D.ink2)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(D.rule).frame(height: 1) }
    }

    private var local: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                label("Local only", "Free")
                Text("Nothing leaves your Mac. This is noticeably worse than the API option.")
                    .font(D.font(13.5)).foregroundStyle(D.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            LineButton(title: "Use local only", action: useLocal)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(D.rule).frame(height: 1) }
    }

    private func label(_ title: String, _ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(D.font(15, .medium))
            Text(note).font(D.font(13.5)).foregroundStyle(D.ink3)
        }
    }

    /// A typed key replaces the saved one; with the field empty, the saved key is kept.
    private func useHaiku() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            guard keySaved else { return }
        } else {
            keyFailed = !AnthropicCleanupBackend.saveAPIKey(key)
            if keyFailed { return }
        }
        AnthropicCleanupBackend.localOnly = false
        onContinue()
    }

    private func useLocal() {
        AnthropicCleanupBackend.localOnly = true
        onContinue()
    }
}

private struct PermissionsStep: View {
    @ObservedObject var appState: AppState
    let onContinue: () -> Void

    @State private var mic = PermissionChecker.microphoneStatus() == .authorized
    @State private var accessibility = PermissionChecker.checkAccessibility()
    @State private var inputMonitoring = PermissionChecker.checkInputMonitoring()
    @State private var grantedHere = false  // a key listener only sees a new permission after a restart
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Three permissions").font(D.font(32, .bold))
            Text("macOS asks for these before Diction can hear you and type where your cursor is.")
                .font(D.font(16)).foregroundStyle(D.ink2)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 480, alignment: .leading)

            VStack(spacing: 0) {
                row("Microphone", "To hear what you say", granted: mic) {
                    Task {
                        if PermissionChecker.microphoneStatus() == .notDetermined {
                            mic = await PermissionChecker.checkMicrophone()
                        } else {
                            PermissionChecker.openMicrophoneSettings()
                        }
                    }
                }
                row("Accessibility", "To paste into the app you're using", granted: accessibility) {
                    PermissionChecker.promptAccessibility()
                    PermissionChecker.openAccessibilitySettings()
                }
                row("Input Monitoring", "To notice when you hold the shortcut", granted: inputMonitoring) {
                    PermissionChecker.promptInputMonitoring()
                    PermissionChecker.openInputMonitoringSettings()
                }
            }
            .frame(maxWidth: 520)
            .padding(.top, 6)

            if allGranted && grantedHere {
                HStack(spacing: 14) {
                    WhiteButton(title: "Restart Diction") {
                        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                        appState.relaunchApp()
                    }
                    Text("macOS applies new permissions after a restart.").font(D.font(13.5)).foregroundStyle(D.ink2)
                }
                .padding(.top, 8)
            } else if allGranted {
                WhiteButton(title: "Continue", action: onContinue).padding(.top, 8)
            }
        }
        .onReceive(poll) { _ in
            let now = (PermissionChecker.microphoneStatus() == .authorized, PermissionChecker.checkAccessibility(),
                       PermissionChecker.checkInputMonitoring())
            if (!accessibility && now.1) || (!inputMonitoring && now.2) { grantedHere = true }
            (mic, accessibility, inputMonitoring) = now
        }
    }

    private var allGranted: Bool { mic && accessibility && inputMonitoring }

    private func row(_ title: String, _ subtitle: String, granted: Bool, allow: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(D.font(15, .medium))
                Text(subtitle).font(D.font(13.5)).foregroundStyle(D.ink2)
            }
            Spacer()
            if granted {
                Text("Allowed").font(D.font(13.5)).foregroundStyle(D.ink2)
            } else {
                LineButton(title: "Allow", action: allow)
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(D.rule).frame(height: 1) }
    }
}

/// A real dictation into a practice field.
private struct TryItStep: View {
    @ObservedObject var appState: AppState
    let onFinish: () -> Void
    @State private var text = ""
    @State private var started = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Try it").font(D.font(32, .bold))
            Text(appState.isReady
                 ? "Hold \(appState.pushToTalkChord.displayString) and say a sentence. When you let go, it appears below."
                 : "Getting the speech model ready…")
                .font(D.font(16)).foregroundStyle(D.ink2)

            TextEditor(text: $text)
                .font(D.font(15))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($focused)
                .padding(12)
                .frame(maxWidth: 520, minHeight: 110, maxHeight: 130)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.35)))

            Group {
                if text.isEmpty {
                    LineButton(title: "Skip") { finish() }
                } else {
                    WhiteButton(title: "Done") { finish() }
                }
            }
            .padding(.top, 4)
        }
        .task {
            focused = true
            guard !started else { return }
            started = true
            await appState.initialize(skipPermissionPrompts: true)
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        onFinish()
    }
}
