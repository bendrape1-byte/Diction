// Self-check for the meeting files: front matter round trip, INDEX.md, and the move from the old day-folder layout.
// Run: swiftc Diction/Meeting/{MeetingTranscript,MeetingMarkdownWriter,MeetingHistory}.swift scripts/meetingcheck/main.swift -o /tmp/meetingcheck && /tmp/meetingcheck
import Foundation

MainActor.assumeIsolated {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meetingcheck-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let start = Date(timeIntervalSince1970: 1_793_000_000)
    let t = MeetingTranscript(meetingName: "Weekly sync: pricing / Q4", startDate: start)
    t.endDate = start.addingTimeInterval(72 * 60)
    t.attendees = [MeetingAttendee(name: "Anna Berg"), MeetingAttendee(name: "Lee, Jr")]
    t.meetingDescription = "Anna and Lee settle Q4 pricing: \"Pro\" goes to 12 € #decided."
    t.summary = "- Pro plan costs 12 €\n- Lee sends the invoice draft by Friday"
    t.segments = [
        TranscriptSegment(id: UUID(), speaker: .me, startTime: 0, endTime: 4, text: "Let's start."),
        TranscriptSegment(id: UUID(), speaker: .remote(name: "Speaker 1"), startTime: 3725, endTime: 3730, text: "Twelve euros, then."),
    ]
    let url = try! MeetingMarkdownWriter.write(transcript: t, to: dir)
    let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
    let d = day.string(from: start)
    assert(url.lastPathComponent == "\(d) Weekly sync pricing Q4.md", url.lastPathComponent)

    let back = try! MeetingMarkdownWriter.parse(from: url)
    assert(back.meetingName == t.meetingName)
    assert(abs(back.startDate.timeIntervalSince(start)) < 1)
    assert(back.formattedDuration == "1h 12m")
    assert(back.attendees.map(\.name) == ["Anna Berg", "Lee, Jr"])
    assert(back.meetingDescription == t.meetingDescription)
    assert(back.summary == t.summary)
    assert(back.segments.map(\.text) == ["Let's start.", "Twelve euros, then."])
    assert(back.segments.map(\.speaker.displayName) == ["Me", "Speaker 1"])
    assert(back.segments[1].formattedTimestamp == "1:02:05")
    // writing what was read gives the same file
    _ = try! MeetingMarkdownWriter.write(transcript: back, to: dir, existingFileURL: url)
    let copy = dir.appendingPathComponent("copy.md")
    _ = try! MeetingMarkdownWriter.write(transcript: t, to: dir, existingFileURL: copy)
    assert(try! String(contentsOf: url, encoding: .utf8) == String(contentsOf: copy, encoding: .utf8))
    try! FileManager.default.removeItem(at: copy)

    // a meeting without a summary uses its title as the description; a second one that day gets " 2"
    let older = MeetingTranscript(meetingName: "Intro call", startDate: start.addingTimeInterval(-86_400))
    _ = try! MeetingMarkdownWriter.write(transcript: older, to: dir)
    let twin = MeetingTranscript(meetingName: "Weekly sync: pricing / Q4", startDate: start.addingTimeInterval(60))
    let twinURL = try! MeetingMarkdownWriter.write(transcript: twin, to: dir)
    assert(twinURL.lastPathComponent == "\(d) Weekly sync pricing Q4 2.md")

    let index = try! String(contentsOf: dir.appendingPathComponent("INDEX.md"), encoding: .utf8)
    let rows = index.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
    assert(rows == [
        "- \(d) · Weekly sync: pricing / Q4 · Weekly sync: pricing / Q4 · \(d) Weekly sync pricing Q4 2.md",
        "- \(d) · Weekly sync: pricing / Q4 · \(t.meetingDescription!) · \(d) Weekly sync pricing Q4.md",
        "- \(day.string(from: older.startDate)) · Intro call · Intro call · \(day.string(from: older.startDate)) Intro call.md",
    ], rows.joined(separator: "\n"))
    assert(FileManager.default.fileExists(atPath: dir.appendingPathComponent("README.md").path))
    assert(MeetingHistory.loadEntries(from: dir).count == 3)  // README and INDEX aren't meetings

    // Old layout: day folders → flat files + INDEX.md, originals moved untouched into the backup folder.
    let old = FileManager.default.temporaryDirectory.appendingPathComponent("meetingcheck-old-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: old) }
    let recorded = """
        # Open zoom.us?

        **Date:** 24. Oct 2026 at 23:33 — 00:11

        ## Notes

        *No notes.*

        ## Transcript

        **[00:00] Me:** All right, let's start.  
        **[00:30] Speaker 1:** Sounds good.  

        """
    let imported = """
        ---
        date: 2026-09-22T17:15:57Z
        imported_from: elsewhere
        ---

        # Final Call

        **Date:** Sep 22, 2026 at 19:15 — 19:56

        ## Summary

        Booking site decisions: new clients pay upfront, returning clients pay nothing.

        ### Payment
        - Stripe confirmed.

        ## Transcript

        **[00:06] Speaker 1:** Yeah.  

        """
    let empty = "# Discord\n\n**Date:** 26. Jul 2026 at 14:23 (in progress)\n\n## Transcript\n\n*No transcript yet.*\n"
    for (path, text) in [("2026-10-24/meeting-at-23-33.md", recorded), ("2026-09-22/import-1.md", imported), ("2026-07-26/discord.md", empty)] {
        let file = old.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: file, atomically: true, encoding: .utf8)
    }
    MeetingHistory.migrateOldLayout(in: old)

    let top = try! FileManager.default.contentsOfDirectory(atPath: old.path).sorted()
    assert(top == ["2026-09-22 Final Call.md", "2026-10-24 Open zoom.us?.md", "INDEX.md", "Old layout backup", "README.md"], "\(top)")
    let backup = old.appendingPathComponent("Old layout backup")
    assert(try! FileManager.default.contentsOfDirectory(atPath: backup.path).sorted() == ["2026-07-26", "2026-09-22", "2026-10-24"])
    assert(try! String(contentsOf: backup.appendingPathComponent("2026-07-26/discord.md"), encoding: .utf8) == empty)  // kept, not migrated
    assert(try! String(contentsOf: backup.appendingPathComponent("2026-10-24/meeting-at-23-33.md"), encoding: .utf8) == recorded)

    let moved = try! MeetingMarkdownWriter.parse(from: old.appendingPathComponent("2026-10-24 Open zoom.us?.md"))
    assert(Calendar.current.dateComponents([.hour, .minute], from: moved.startDate) == DateComponents(hour: 23, minute: 33))
    assert(moved.formattedDuration == "38m")  // across midnight
    assert(moved.segments.count == 2 && moved.summary == nil)
    let movedImport = try! MeetingMarkdownWriter.parse(from: old.appendingPathComponent("2026-09-22 Final Call.md"))
    assert(movedImport.formattedDuration == "41m")
    assert(movedImport.meetingDescription == "Booking site decisions: new clients pay upfront, returning clients pay nothing.")
    assert(movedImport.importedFrom == "elsewhere")
    let oldIndex = try! String(contentsOf: old.appendingPathComponent("INDEX.md"), encoding: .utf8)
    assert(oldIndex.components(separatedBy: "\n").filter { $0.hasPrefix("- ") } == [
        "- 2026-10-24 · Open zoom.us? · Open zoom.us? · 2026-10-24 Open zoom.us?.md",
        "- 2026-09-22 · Final Call · \(movedImport.meetingDescription!) · 2026-09-22 Final Call.md",
    ], oldIndex)
    MeetingHistory.migrateOldLayout(in: old)  // a second launch finds nothing to do
    assert(try! FileManager.default.contentsOfDirectory(atPath: old.path).count == top.count)
    print("meetingcheck ok")
}
