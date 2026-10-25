import SwiftUI

/// Loads the font and the default Haiku prompt, and clicking the Dock icon while the window is closed opens it again.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onReopen: (() -> Void)?
    func applicationWillFinishLaunching(_ notification: Notification) {
        D.registerFonts()
        AnthropicCleanupBackend.installDefaultPromptIfMissing()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { onReopen?() }
        return true
    }
}

@main
struct DictionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private static let automaticTerminationReason = "Diction keeps a persistent menu bar presence."
    @StateObject private var appState = AppState()
    @State private var hasStarted = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            Group {
                switch appState.status {
                case .recording:
                    Image("MenuBarIconRedDim").renderingMode(.original)
                case .error:
                    Image(systemName: "exclamationmark.triangle")
                default:
                    Image("MenuBarIcon").renderingMode(.template)
                }
            }
            .onAppear {
                ProcessInfo.processInfo.disableAutomaticTermination(Self.automaticTerminationReason)
                guard !hasStarted else { return }
                hasStarted = true
                #if DEBUG
                let args = ProcessInfo.processInfo.arguments
                if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
                    Snapshot.run(appState: appState, to: URL(fileURLWithPath: args[i + 1]))
                    return
                }
                #endif
                appDelegate.onReopen = { [appState] in appState.showHub() }
                if ProcessInfo.processInfo.arguments.contains("--force-onboarding") {
                    UserDefaults.standard.set(false, forKey: "onboardingCompleted")
                }
                Task { await appState.start() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                ProcessInfo.processInfo.enableAutomaticTermination(Self.automaticTerminationReason)
                appState.prepareForTermination()
            }
        }
    }
}

#if DEBUG
/// `--snapshot <folder>`: draws every page, the settings, the first-run screen, the meeting prompt and the indicator states into PNGs
/// and quits, so the UI can be checked without clicking through it. Also notes which view a click on the tabs reaches.
@MainActor
enum Snapshot {
    static func run(appState: AppState, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plate = LinePlate.size
        var shots: [(String, NSView, NSSize)] = HubPage.allCases.map {
            ($0.rawValue, NSHostingView(rootView: HubView(appState: appState, page: $0)), NSSize(width: 600, height: 780))
        }
        shots += [
            ("settings", fixedSize(SettingsView(appState: appState)), NSSize(width: 520, height: 1180)),
            ("meeting-prompt", fixedSize(MeetingPromptView(meetingName: "Zoom — 10:03", start: {}, dismiss: {})), NSSize(width: 440, height: 210)),
            ("onboarding", fixedSize(OnboardingView(appState: appState, step: .welcome, onFinish: {})), NSSize(width: 640, height: 600)),
            ("permissions", fixedSize(OnboardingView(appState: appState, step: .permissions, onFinish: {})), NSSize(width: 640, height: 600)),
            ("plate-listening", NSHostingView(rootView: LinePlate(mode: .listening, level: { 0.6 })), plate),
            ("plate-handsfree", NSHostingView(rootView: LinePlate(mode: .handsFree, level: { 0.4 })), plate),
            ("plate-notes", NSHostingView(rootView: LinePlate(mode: .notes)), plate),
            ("plate-copied", NSHostingView(rootView: OverlayPillView(message: .clipboardFallback(appName: "Slack"))), NSSize(width: 300, height: 44)),
        ]
        let windows = shots.map { name, view, size -> (String, NSWindow) in
            let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: 0), size: size),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = view
            w.orderFront(nil)
            return (name, w)
        }

        // the real window style: do clicks on the tabs in the title bar reach the SwiftUI buttons?
        let hub = NSWindow(contentRect: NSRect(x: -6000, y: 900, width: 600, height: 780),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        hub.titlebarAppearsTransparent = true
        hub.titleVisibility = .hidden
        let hosting = NSHostingView(rootView: HubView(appState: appState))
        hub.contentView = hosting
        hub.orderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for (name, w) in windows {
                guard let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
            }
            let frame = hosting.superview!
            let report = [("History", 110.0), ("Style", 330.0), ("Settings", 572.0)].map { label, x -> String in
                let hit = frame.hitTest(NSPoint(x: x, y: frame.bounds.height - 15))
                return "\(label): \(hit.map { String(describing: type(of: $0)) } ?? "nil"), inside SwiftUI: \(hit?.isDescendant(of: hosting) == true)"
            }
            try? report.joined(separator: "\n").write(to: dir.appendingPathComponent("hittest.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    /// Like the first-run window: the view gets the window's size instead of setting it.
    private static func fixedSize<V: View>(_ view: V) -> NSView {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        return hosting
    }
}
#endif
