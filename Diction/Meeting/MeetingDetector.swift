import AppKit
import CoreAudio
import Foundation

/// Detected meeting app info.
struct DetectedMeeting {
    let appName: String
    let bundleIdentifier: String
    let suggestedName: String // e.g. "Zoom — 10:03 AM"
}

/// Notices when a call starts: a meeting app, or a browser with a meeting tab, has the microphone open.
/// Being in front isn't enough (that made an empty "meeting" for Discord), and video sites never use the mic.
/// Off by default — must be explicitly enabled via Settings.
@MainActor
final class MeetingDetector {
    var onMeetingDetected: ((DetectedMeeting) -> Void)?

    private var pollTimer: Timer?
    private var isRunning = false

    /// Apps already asked about during their current mic use; forgotten once they let go of the mic,
    /// so the next call in the same app asks again.
    private var promptedBundleIDs: Set<String> = []

    /// Bundle IDs of known meeting/video call apps.
    private static let knownMeetingApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "us.zoom.videomeeting": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.cisco.webex.meetings": "Webex",
        "com.google.hangouts": "Google Meet",
        "com.slack.Slack": "Slack",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
    ]

    /// Window title patterns that suggest a browser-based meeting is active.
    private static let browserMeetingPatterns: [String] = [
        "meet.google.com",
        "google meet",
        "meet -",
        "zoom.us/j/",
        "zoom.us/wc/",
        "teams.microsoft.com",
        "teams.live.com",
        "whereby.com",
    ]

    /// Bundle IDs of common browsers.
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser", // Arc
        "com.brave.Browser",
        "com.operasoftware.Opera",
    ]

    /// Start polling the microphone.
    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Poll every 5 seconds — cheap operation.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkForMeetingApps()
        }

        // Also check immediately.
        checkForMeetingApps()
    }

    /// Stop polling.
    func stop() {
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Apps that have the microphone open right now, Diction itself left out. A helper process counts for its
    /// app (Chrome's audio runs in "com.google.Chrome.helper"), and Safari records in WebKit's GPU process.
    /// Asks CoreAudio's per-process objects (macOS 14.2+; empty on older systems).
    static func appsUsingMicrophone() -> Set<String> {
        let known = Array(knownMeetingApps.keys) + browserBundleIDs
        var apps: Set<String> = []
        for process in processObjects()
        where uint32(process, kAudioProcessPropertyIsRunningInput) == 1 {
            guard let raw = bundleID(process), raw != Bundle.main.bundleIdentifier else { continue }
            let id = raw.lowercased()
            if id == "com.apple.webkit.gpu" { apps.insert("com.apple.Safari"); continue }
            // longest match, so "com.microsoft.teams2.helper" is Teams 2, not classic Teams
            apps.insert(known.filter { id.hasPrefix($0.lowercased()) }.max { $0.count < $1.count } ?? raw)
        }
        return apps
    }

    // MARK: - Private

    private func checkForMeetingApps() {
        let micApps = Self.appsUsingMicrophone()
        promptedBundleIDs.formIntersection(micApps)

        for bundleID in micApps.subtracting(promptedBundleIDs) {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }
            let titles = AccessibilityWindowTitles.all(for: app)
            let meeting: DetectedMeeting
            if let appName = Self.knownMeetingApps[bundleID] {
                meeting = DetectedMeeting(
                    appName: appName,
                    bundleIdentifier: bundleID,
                    suggestedName: MeetingWindowHeuristics.bestMeetingTitle(in: titles, appName: appName)
                        ?? Self.suggestedMeetingName(appName: appName)
                )
            } else if Self.browserBundleIDs.contains(bundleID), let meetingName = matchMeetingPattern(in: titles) {
                meeting = DetectedMeeting(
                    appName: meetingName,
                    bundleIdentifier: bundleID,
                    suggestedName: Self.suggestedMeetingName(appName: meetingName)
                )
            } else {
                continue  // a browser on the mic without a meeting tab (yet): look again next poll
            }
            promptedBundleIDs.insert(bundleID)
            onMeetingDetected?(meeting)
            return
        }
    }

    /// Every process CoreAudio knows about, one audio object each.
    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func bundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let id = value?.takeRetainedValue() as String?, !id.isEmpty else { return nil }
        return id
    }

    /// Check if any window title matches a browser-based meeting.
    private func matchMeetingPattern(in titles: [String]) -> String? {
        for title in titles {
            let lowered = title.lowercased()
            for pattern in Self.browserMeetingPatterns {
                if lowered.contains(pattern) {
                    if lowered.contains("meet.google.com") || lowered.contains("google meet") || lowered.hasPrefix("meet -") { return "Google Meet" }
                    if lowered.contains("zoom.us") { return "Zoom" }
                    if lowered.contains("teams.microsoft.com") || lowered.contains("teams.live.com") { return "Microsoft Teams" }
                    if lowered.contains("whereby.com") { return "Whereby" }
                    return "Video Call"
                }
            }
        }
        return nil
    }

    /// Generate a default meeting name like "Zoom — 10:03 AM".
    private static func suggestedMeetingName(appName: String) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "\(appName) — \(formatter.string(from: Date()))"
    }
}
