import AppKit

/// Which app a dictation goes to, read when recording starts: the app's name and the title of its front window
/// (browsers put the tab title there, "Inbox – Gmail"). Haiku gets it as one line, so it can format for that app.
/// No OCR: two Accessibility reads, a few ms.
enum AppContext {
    enum Category: String { case email, chat, agent, docs, other }

    // ponytail: one fixed table, no settings. Add an app here when it lands in the wrong category.
    private static let bundleIDs: [String: Category] = [
        "com.apple.mail": .email, "com.microsoft.Outlook": .email, "com.readdle.SparkDesktop": .email,
        "com.superhuman.electron": .email,
        "ru.keepcoder.Telegram": .chat, "org.telegram.desktop": .chat, "net.whatsapp.WhatsApp": .chat,
        "com.tinyspeck.slackmacgap": .chat, "com.hnc.Discord": .chat, "com.apple.MobileSMS": .chat,
        "org.whispersystems.signal-desktop": .chat, "com.microsoft.teams2": .chat,
        "com.apple.Terminal": .agent, "com.googlecode.iterm2": .agent, "com.mitchellh.ghostty": .agent,
        "dev.warp.Warp-Stable": .agent, "com.anthropic.claudefordesktop": .agent, "com.openai.chat": .agent,
        "com.openai.codex": .agent, "com.todesktop.230313mzl4w4u92": .agent, "com.microsoft.VSCode": .agent,
        "com.exafunction.windsurf": .agent, "dev.zed.Zed": .agent, "com.apple.dt.Xcode": .agent,
        "com.apple.Notes": .docs, "notion.id": .docs, "com.microsoft.Word": .docs, "com.apple.iWork.Pages": .docs,
        "md.obsidian": .docs,
    ]
    // For apps not in the table (browsers, mostly): the first keyword found in the window title wins,
    // so a Gmail tab whose subject mentions Slack stays email.
    private static let titleKeywords: [(String, Category)] = [
        ("gmail", .email), ("outlook", .email), ("proton mail", .email), ("superhuman", .email),
        ("telegram", .chat), ("whatsapp", .chat), ("slack", .chat), ("discord", .chat), ("messenger", .chat),
        ("claude", .agent), ("chatgpt", .agent), ("codex", .agent),
        ("google docs", .docs), ("notion", .docs),
    ]

    static func category(bundleID: String?, title: String) -> Category {
        if let bundleID, let category = bundleIDs[bundleID] { return category }
        let title = title.lowercased()
        return titleKeywords.first { title.contains($0.0) }?.1 ?? .other
    }

    /// The line Haiku gets. For agent apps also the Mac user name and home folder, so "users alex mar" can
    /// become /Users/alexmar.
    static func line(appName: String, bundleID: String?, title: String) -> (category: Category, line: String) {
        let category = category(bundleID: bundleID, title: title)
        var line = "Target app: \(appName), window title \"\(title)\", category: \(category.rawValue)."
        if category == .agent {
            line += " Mac user name: \(NSUserName()), home folder: \(NSHomeDirectory())."
        }
        return (category, line)
    }

    // ponytail: the first window Accessibility lists is the front one; kAXFocusedWindow if that ever isn't so
    static func read(_ app: NSRunningApplication) -> (category: Category, line: String) {
        line(appName: app.localizedName ?? "unknown", bundleID: app.bundleIdentifier,
             title: AccessibilityWindowTitles.all(for: app).first ?? "")
    }
}
