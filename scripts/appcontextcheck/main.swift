// Self-check for the category table in AppContext.swift.
// Run: swiftc Diction/Cleanup/AppContext.swift Diction/Meeting/AccessibilityWindowTitles.swift scripts/appcontextcheck/main.swift -o /tmp/appcontextcheck && /tmp/appcontextcheck
import Foundation

let cases: [(String?, String, AppContext.Category)] = [
    ("ru.keepcoder.Telegram", "Telegram", .chat),
    ("com.google.Chrome", "Telegram Web", .chat),
    ("com.apple.Safari", "Inbox (3) – alex@example.com – Gmail", .email),
    ("com.google.Chrome", "Slack is down again - Gmail", .email),  // email keyword comes first
    ("com.apple.Terminal", "claude-dictation — -zsh — 80×24", .agent),
    ("com.mitchellh.ghostty", "~/claude-code/Diction", .agent),
    ("company.thebrowser.Browser", "Fix the paste bug - Claude", .agent),
    ("com.anthropic.claudefordesktop", "", .agent),
    ("com.apple.Notes", "Slack ideas", .docs),  // the app wins over the title
    ("com.google.Chrome", "Projektplan - Google Docs", .docs),
    ("com.apple.finder", "Downloads", .other),
    (nil, "", .other),
]
for (bundleID, title, expected) in cases {
    let got = AppContext.category(bundleID: bundleID, title: title)
    assert(got == expected, "\(bundleID ?? "nil") \"\(title)\": \(got), expected \(expected)")
}
let agent = AppContext.line(appName: "Terminal", bundleID: "com.apple.Terminal", title: "x")
assert(agent.line.contains("home folder: \(NSHomeDirectory())"))
assert(!AppContext.line(appName: "Telegram", bundleID: "ru.keepcoder.Telegram", title: "x").line.contains("home folder"))
print("appcontextcheck: \(cases.count) cases ok")
