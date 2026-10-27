import Foundation

/// A past meeting found on disk.
struct MeetingHistoryEntry: Identifiable, Hashable {
    var id: URL { fileURL }
    let fileURL: URL
    let name: String
    let date: Date
    let description: String
}

/// Lists the meeting files in the save folder and keeps INDEX.md and README.md next to them.
enum MeetingHistory {
    /// Every meeting, newest first. Reads only the top of each file: front matter and title.
    static func loadEntries(from baseDirectory: URL) -> [MeetingHistoryEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.pathExtension == "md" && !["README.md", "INDEX.md"].contains($0.lastPathComponent) }
            .map(entry(for:))
            .sorted { $0.date > $1.date }
    }

    /// INDEX.md is rebuilt from the files themselves after every write, so it can't drift from them.
    /// README.md is written once and left alone after that.
    static func rebuildIndex(in baseDirectory: URL) {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let lines = loadEntries(from: baseDirectory).map {
            "- \(day.string(from: $0.date)) · \($0.name) · \($0.description) · \($0.fileURL.lastPathComponent)"
        }
        let index = "# Meetings\n\nNewest first: date · title · what it was about · file.\n\n" + lines.joined(separator: "\n") + "\n"
        try? index.write(to: baseDirectory.appendingPathComponent("INDEX.md"), atomically: true, encoding: .utf8)

        let readme = baseDirectory.appendingPathComponent("README.md")
        if !FileManager.default.fileExists(atPath: readme.path) {
            try? readmeText.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    /// Older versions saved meetings as "<yyyy-MM-dd>/<slug>.md". Turns those into the flat files above, then moves the
    /// day folders, untouched, into "Old layout backup/". Files without a transcript are only kept in the backup.
    /// Runs at every launch; with no day folders left it only lists the folder.
    @MainActor
    static func migrateOldLayout(in baseDirectory: URL) {
        let fm = FileManager.default
        let days = ((try? fm.contentsOfDirectory(atPath: baseDirectory.path)) ?? [])
            .filter { $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }
            .sorted()
        guard !days.isEmpty else { return }
        let backup = baseDirectory.appendingPathComponent("Old layout backup")
        let dayAndTime = DateFormatter()
        dayAndTime.dateFormat = "yyyy-MM-dd HH:mm"

        for day in days {
            let folder = baseDirectory.appendingPathComponent(day)
            for name in ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() where name.hasSuffix(".md") {
                let file = folder.appendingPathComponent(name)
                guard let content = try? String(contentsOf: file, encoding: .utf8),
                      let t = try? MeetingMarkdownWriter.parse(from: file),
                      !t.segments.isEmpty else { continue }

                // The old files keep their times in a "**Date:** 24. Oct 2026 at 23:33 — 00:11" line.
                let times = (content.components(separatedBy: "\n").first { $0.hasPrefix("**Date:**") } ?? "")
                    .matches(of: #/(\d{1,2}):(\d{2})/#).compactMap { match in Int(match.1).flatMap { h in Int(match.2).map { h * 60 + $0 } } }
                if !(content.hasPrefix("---") && content.contains("\ndate:")) {
                    let start = times.first ?? 12 * 60
                    t.startDate = dayAndTime.date(from: "\(day) \(start / 60):\(start % 60)") ?? t.startDate
                }
                t.endDate = times.count >= 2
                    ? t.startDate.addingTimeInterval(Double((times[1] - times[0] + 1440) % 1440) * 60)
                    : t.startDate.addingTimeInterval(t.segments.last?.endTime ?? 0)  // was still "in progress"

                // a summary that opens with a one-sentence overview gives the description
                if let first = t.summary?.components(separatedBy: "\n\n").first?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let firstCharacter = first.first, !"-*#".contains(firstCharacter) {
                    t.meetingDescription = first
                }
                _ = try? MeetingMarkdownWriter.write(transcript: t, to: baseDirectory)
            }

            try? fm.createDirectory(at: backup, withIntermediateDirectories: true)
            var target = backup.appendingPathComponent(day)
            var counter = 2
            while fm.fileExists(atPath: target.path) {
                target = backup.appendingPathComponent("\(day) \(counter)")
                counter += 1
            }
            try? fm.moveItem(at: folder, to: target)
        }
    }

    private static func entry(for file: URL) -> MeetingHistoryEntry {
        // 4 KB covers the front matter and the "# " title; the transcript after it can be long
        let handle = try? FileHandle(forReadingFrom: file)
        let head = (try? handle?.read(upToCount: 4096)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        try? handle?.close()

        var date: Date?
        var title: String?
        var description: String?
        for line in head.components(separatedBy: .newlines) {
            if date == nil, line.hasPrefix("date:") {
                date = MeetingMarkdownWriter.parseFrontmatterDate(String(line.dropFirst("date:".count)))
            } else if description == nil, line.hasPrefix("description:") {
                description = MeetingMarkdownWriter.stripWrappingQuotes(String(line.dropFirst("description:".count)))
            } else if line.hasPrefix("# ") {
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? file.deletingPathExtension().lastPathComponent
        return MeetingHistoryEntry(
            fileURL: file,
            name: name,
            // a file dropped in by hand may have no front matter
            date: date ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast,
            description: description ?? name
        )
    }

    private static let readmeText = """
        # Diction Meetings

        Diction saves one Markdown file here for each meeting it takes notes in.

        ## Where to look

        - `INDEX.md` lists every meeting on one line, newest first: date · title · what it was about · file name. Read it first, then open the file you need.
        - `<date> <title>.md` holds one meeting. It opens with front matter (`date`, `duration`, `attendees`, `description`). After that comes `## Summary` with decisions, action items and open questions, if a summary was made, and then `## Transcript`, one line per turn: `**[mm:ss] Speaker:** text`. "Me" is whoever runs Diction.

        ## Searching

        - Topic or person: search `INDEX.md`, for example `grep -i "pricing" INDEX.md`.
        - Who said something: `grep -il "stripe" *.md` lists the files that mention it. Read the transcript in those.
        - File names start with the date, so `ls 2026-10-*` shows October 2026.

        Transcripts come from speech recognition, so names are often misspelled ("Clawed" for "Claude"). If a name finds nothing, try another spelling or a word from the topic.

        Diction rebuilds `INDEX.md` from the meeting files every time it writes one. Edit the meeting files, not the index. Diction writes this README once and doesn't touch it again.

        """
}
