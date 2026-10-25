// Self-check for the style, snippet and spiral logic in HubData.swift.
// Run: swiftc Diction/UI/HubData.swift scripts/hubcheck/main.swift -o /tmp/hubcheck && /tmp/hubcheck
import Foundation

let t = "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you."
assert(StyleFormatter.apply(t, style: .formal) == t)
assert(StyleFormatter.apply(t, style: .casual) == "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you")
assert(StyleFormatter.apply(t, style: .veryCasual) == "hey, are you free for lunch tomorrow? let's do 12 if that works for you")
assert(StyleFormatter.apply("I think so. AI is fun.", style: .veryCasual) == "I think so. AI is fun")
assert(StyleFormatter.apply("See you soon.", style: .excited) == "See you soon!")
assert(StyleFormatter.apply("Wait...", style: .casual) == "Wait...")
let s = [Snippet(trigger: "my email address", expansion: "me@example.com")]
assert(SnippetExpander.expand("My email address.", snippets: s) == "me@example.com")
assert(SnippetExpander.expand("Send it to my email address please.", snippets: s) == "Send it to me@example.com please.")
assert(SnippetExpander.expand("Nothing here.", snippets: s) == "Nothing here.")

// Spiral: one line per dictation, all inside the square, each one starting farther out than the one before.
let start = Date(timeIntervalSince1970: 1_780_000_000)
let records = (0..<60).map { i in
    DictationRecord(date: start.addingTimeInterval(Double(i) * 5_000), text: Array(repeating: "word", count: i % 9 + 1).joined(separator: " "), raw: "")
}
let lines = Spiral.segments(records.shuffled(), size: 236)
assert(lines.count == 60 && lines.allSatisfy { $0.count >= 3 })
assert(lines.joined().allSatisfy { (0...236).contains($0.x) && (0...236).contains($0.y) })
let radii = lines.map { hypot($0[0].x - 118, $0[0].y - 118) }
assert(zip(radii, radii.dropFirst()).allSatisfy { $0 < $1 })
assert(Spiral.segments([], size: 236).isEmpty)
print("hubcheck ok")
