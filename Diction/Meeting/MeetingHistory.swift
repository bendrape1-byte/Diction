import Foundation

/// A past meeting found on disk.
struct MeetingHistoryEntry: Identifiable, Hashable {
    let id: URL
    let name: String
    let dateFolder: String
    let fileURL: URL

    var displayDate: String { dateFolder }
}

/// Scans the meeting save directory for past transcript markdown files.
enum MeetingHistory {
    /// Returns all meeting entries grouped by date folder, newest first.
    static func loadEntries(from baseDirectory: URL) -> [(date: String, entries: [MeetingHistoryEntry])] {
        let fm = FileManager.default
        guard let dateFolders = try? fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var groups: [(date: String, entries: [MeetingHistoryEntry])] = []

        let sortedFolders = dateFolders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } // newest date first

        for folder in sortedFolders {
            let dateFolder = folder.lastPathComponent
            guard let files = try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            let mdFiles = files
                .filter { $0.pathExtension == "md" }
                .sorted {
                    // Sort by filename (contains the time slug) — stable and doesn't change on save
                    $0.lastPathComponent > $1.lastPathComponent
                }

            let entries = mdFiles.map { file in
                let displayName = MeetingHistory.readTitle(from: file)
                    ?? file.deletingPathExtension().lastPathComponent
                        .replacingOccurrences(of: "-", with: " ")
                        .capitalized
                return MeetingHistoryEntry(id: file, name: displayName, dateFolder: dateFolder, fileURL: file)
            }

            if !entries.isEmpty {
                groups.append((date: dateFolder, entries: entries))
            }
        }
        return groups
    }

    /// Read the "# " title from a markdown file without parsing the whole thing.
    private static func readTitle(from fileURL: URL) -> String? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: .newlines) where line.hasPrefix("# ") {
            let t = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        return nil
    }
}
