import AppKit
import SwiftUI

// The other Diction pages: Meetings, Dictionary, Swaps, Style.

// MARK: - Meetings

struct NotesPage: View {
    @ObservedObject var appState: AppState
    @State private var entries: [MeetingHistoryEntry] = []
    @State private var open: MeetingHistoryEntry?
    @State private var transcript: MeetingTranscript?

    private var saveDir: URL { MeetingTranscriptSettings.loadSaveDirectory() ?? MeetingTranscriptSettings.defaultSaveDirectory() }
    private static let folderFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    var body: some View {
        Group {
            if let open { reader(open) } else { list }
        }
        .onAppear(perform: reload)
        .onChange(of: appState.activeMeetingSession == nil) { _, _ in reload() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let session = appState.activeMeetingSession {
                    NotesControl(session: session, stop: appState.stopMeetingTranscription, fileCreated: reload)
                } else {
                    WhiteButton(title: "Start notes") {
                        appState.startMeetingTranscription(meetingName: "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))")
                    }
                }
            }
            .frame(minHeight: 36, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 8)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if entries.isEmpty {
                        Text("Start notes when a call begins. Each meeting lands here as a transcript.")
                            .font(D.font(13.5)).foregroundStyle(D.ink3).padding(.top, 14).padding(.leading, 12)
                    }
                    ForEach(entries) { entry in
                        RowButton {
                            open = entry
                            transcript = try? MeetingMarkdownWriter.parse(from: entry.fileURL)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(entry.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Text(meta(entry)).font(D.font(12.5)).foregroundStyle(D.ink3)
                            }
                        }
                        .contextMenu { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL]) } }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
    }

    private func reader(_ entry: MeetingHistoryEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button { open = nil } label: {
                    Label("Meetings", systemImage: "chevron.left").font(D.font(13)).foregroundStyle(D.ink2)
                }
                .buttonStyle(.plain)
                Text(transcript?.meetingName ?? entry.name).font(D.font(19, .bold)).padding(.top, 14)
                Text(meta(entry)).font(D.font(12.5)).foregroundStyle(D.ink3).padding(.top, 2)
                if let summary = transcript?.summary, !summary.isEmpty {
                    Text(markdown(summary)).font(D.font(14.5)).lineSpacing(4).textSelection(.enabled).padding(.top, 16)
                }
                if let notes = transcript?.notes, !notes.isEmpty {
                    Text(markdown(notes)).font(D.font(14.5)).lineSpacing(4).textSelection(.enabled).padding(.top, 16)
                }
                ForEach(transcript?.segments ?? []) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        (Text(s.speaker.displayName + "  ") + Text(s.formattedTimestamp).font(D.mono(11.5)))
                            .font(D.font(12)).foregroundStyle(D.ink3)
                        Text(s.text).font(D.font(14.5)).lineSpacing(3).textSelection(.enabled)
                    }
                    .padding(.top, 16)
                }
                LineButton(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL]) }
                    .padding(.top, 24)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 6)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reload() {
        entries = MeetingHistory.loadEntries(from: saveDir).flatMap(\.entries)
    }

    /// The day only: imported meetings carry the import time as their file date, not the meeting's.
    private func meta(_ entry: MeetingHistoryEntry) -> String {
        Self.folderFormat.date(from: entry.dateFolder)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            ?? entry.dateFolder
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// While a meeting is recorded: a dashed line that keeps moving, the elapsed time, Stop.
/// Then "Finishing notes…" until the last chunks are transcribed. Watches the session itself, which AppState doesn't republish.
private struct NotesControl: View {
    @ObservedObject var session: MeetingSession
    let stop: () -> Void
    let fileCreated: () -> Void
    @State private var started = Date()

    var body: some View {
        Group {
            if session.isActive {
                HStack(spacing: 12) {
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        Canvas { ctx, size in
                            var line = Path()
                            line.move(to: CGPoint(x: 2, y: size.height / 2))
                            line.addLine(to: CGPoint(x: size.width - 2, y: size.height / 2))
                            ctx.stroke(line, with: .color(.white), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4],
                                                                                    dashPhase: CGFloat((t * 14).truncatingRemainder(dividingBy: 8))))
                        }
                        .frame(width: 92, height: 18)
                    }
                    Text("Taking notes").font(D.font(13.5))
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        let s = Int(context.date.timeIntervalSince(started))
                        Text(String(format: "%02d:%02d", s / 60, s % 60)).font(D.mono(12.5)).foregroundStyle(D.ink2)
                    }
                    LineButton(title: "Stop", action: stop)
                }
            } else {
                Text(session.isDraining ? "Finishing notes…" : "Starting…").font(D.font(13.5)).foregroundStyle(D.ink2)
            }
        }
        .onChange(of: session.isActive) { _, active in if active { started = Date() } }
        .onChange(of: session.fileURL) { _, _ in fileCreated() }  // the running meeting shows up in the list right away
    }
}

/// A list row that lights up under the pointer.
struct RowButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            label
                .font(D.font(14.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? D.raised : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// Asks whether to take notes when a call starts: a small blue window instead of a system alert.
@MainActor
final class MeetingPromptController {
    private var window: NSWindow?

    func show(meetingName: String, onStart: @escaping () -> Void) {
        window?.close()
        let view = MeetingPromptView(meetingName: meetingName,
                                     start: { [weak self] in self?.close(); onStart() },
                                     dismiss: { [weak self] in self?.close() })
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 210),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(D.blue)
        w.isReleasedWhenClosed = false
        w.level = .floating  // stays above the call window it's asking about
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        w.contentView = hosting
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    private func close() {
        window?.close()
        window = nil
    }
}

/// Return starts notes, Esc says not now, like the alert it replaces.
struct MeetingPromptView: View {
    let meetingName: String
    let start: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Start notes for \(meetingName)?")
                .font(D.font(19, .bold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Diction transcribes the call on this Mac.").foregroundStyle(D.ink2)
            HStack(spacing: 10) {
                WhiteButton(title: "Start notes", action: start).keyboardShortcut(.defaultAction)
                LineButton(title: "Not now", action: dismiss).keyboardShortcut(.cancelAction)
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 32)
        .padding(.top, 44)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(D.blue)
        .foregroundStyle(.white)
        .font(D.font(14.5))
        .tint(.white)
    }
}

// MARK: - Dictionary

struct DictionaryPage: View {
    @ObservedObject var corrections: CorrectionStore
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LineField(placeholder: "Add a word, or a fix like clawed → Claude", text: $input, onSubmit: add)
                .padding(.horizontal, 32)
                .padding(.top, 6)
            ScrollView {
                FlowLayout(spacing: 26, lineSpacing: 12) {
                    ForEach(corrections.preferredTranscriptions, id: \.self) { word in
                        WallWord(label: Text(word)) { setWords(corrections.preferredTranscriptions.filter { $0 != word }) }
                    }
                    ForEach(corrections.commonlyMisheard, id: \.self) { fix in
                        WallWord(label: Text(fix.wrong).strikethrough().foregroundColor(D.ink3) + Text(" " + fix.right)) {
                            setFixes(corrections.commonlyMisheard.filter { $0 != fix })
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 18)
                if corrections.preferredTranscriptions.isEmpty && corrections.commonlyMisheard.isEmpty {
                    Text("Add names, jargon and words it keeps getting wrong. The list goes to the cleanup with every dictation.")
                        .font(D.font(13.5)).foregroundStyle(D.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32)
                }
            }
        }
    }

    /// "clawed → Claude" or "clawed -> Claude" is a fix, anything else a word.
    private func add() {
        let parts = input.components(separatedBy: "→").count == 2 ? input.components(separatedBy: "→") : input.components(separatedBy: "->")
        let clean = parts.map { $0.trimmingCharacters(in: .whitespaces) }
        if clean.count == 2, !clean[0].isEmpty, !clean[1].isEmpty {
            setFixes(corrections.commonlyMisheard + [MisheardReplacement(wrong: clean[0], right: clean[1])])
        } else if !clean.joined().isEmpty {
            setWords(corrections.preferredTranscriptions + [input.trimmingCharacters(in: .whitespaces)])
        }
        input = ""
    }

    private func setWords(_ words: [String]) { corrections.updatePreferredTranscriptions(from: words.joined(separator: "\n")) }
    private func setFixes(_ fixes: [MisheardReplacement]) {
        corrections.updateCommonlyMisheard(from: fixes.map { "\($0.wrong) -> \($0.right)" }.joined(separator: "\n"))
    }
}

/// One word on the wall; a small × shows up under the pointer.
private struct WallWord: View {
    let label: Text
    let onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            label.font(D.font(21))
            Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain)
                .foregroundStyle(D.ink3)
                .opacity(hover ? 1 : 0)
                .accessibilityLabel("Remove")
        }
        .onHover { hover = $0 }
    }
}

/// Lays children out left to right and wraps them like words in a paragraph.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, point) in arrange(bounds.width, subviews).points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + rowHeight))
    }
}

// MARK: - Swaps

struct SnippetsPage: View {
    @ObservedObject var store: HubStore
    @State private var say = ""
    @State private var type = ""
    @State private var editing: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 14) {
                LineField(placeholder: "When I say", text: $say, onSubmit: save).frame(maxWidth: 170)
                TextField("Type this", text: $type, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(D.font(14.5))
                    .lineLimit(1...6)
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.35)).frame(height: 1) }
                LineButton(title: editing == nil ? "Add" : "Save", action: save)
            }
            .padding(.horizontal, 32)
            .padding(.top, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.snippets.isEmpty {
                        Text("Say the words on the left and the text on the right gets typed instead: an address, a link, an email you send often.")
                            .font(D.font(13.5)).foregroundStyle(D.ink3).padding(.top, 14).padding(.leading, 12)
                    }
                    ForEach(store.snippets) { s in
                        RowButton { edit(s) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.trigger).font(D.font(16))
                                Text(s.expansion).font(D.font(13.5)).foregroundStyle(D.ink2).lineLimit(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contextMenu {
                            Button("Edit") { edit(s) }
                            Button("Delete", role: .destructive) { store.snippets.removeAll { $0.id == s.id } }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
        }
    }

    private func edit(_ s: Snippet) {
        editing = s.id
        say = s.trigger
        type = s.expansion
    }

    private func save() {
        let trigger = say.trimmingCharacters(in: .whitespaces)
        guard !trigger.isEmpty, !type.isEmpty else { return }
        if let i = store.snippets.firstIndex(where: { $0.id == editing }) {
            store.snippets[i].trigger = trigger
            store.snippets[i].expansion = type
        } else {
            store.snippets.insert(Snippet(trigger: trigger, expansion: type), at: 0)
        }
        editing = nil
        say = ""
        type = ""
    }
}

// MARK: - Style

struct StylePage: View {
    @ObservedObject var appState: AppState
    @AppStorage("style") private var style = StyleChoice.current.rawValue
    @AppStorage("cleanupMedium") private var cleanupMedium = false
    @Namespace private var line
    private let sample = "Sounds good. Let\u{2019}s meet at four."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(StyleChoice.allCases, id: \.self) { choice in
                    let selected = style == choice.rawValue
                    Button {
                        withAnimation(.timingCurve(0.25, 1, 0.5, 1, duration: 0.28)) { style = choice.rawValue }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(StyleFormatter.apply(sample, style: choice)).font(D.font(24))
                            Spacer(minLength: 0)
                            Text(name(choice)).font(D.font(12.5))
                        }
                        .foregroundStyle(selected ? Color.white : D.ink4)
                        .padding(.top, 13)
                        .padding(.bottom, 15)
                        .overlay(alignment: .bottom) {
                            if selected { Rectangle().fill(.white).frame(height: 1.5).matchedGeometryEffect(id: "style", in: line) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Cleanup").font(D.font(14, .bold))
                    HStack(alignment: .top, spacing: 18) {
                        cleanupOption("Off", "Exactly what you said", selected: !appState.cleanupEnabled) {
                            appState.cleanupEnabled = false
                        }
                        cleanupOption("Light", "Removes filler words, fixes punctuation", selected: appState.cleanupEnabled && !cleanupMedium) {
                            appState.cleanupEnabled = true
                            cleanupMedium = false
                        }
                        cleanupOption("Medium", "Also tightens long sentences", selected: appState.cleanupEnabled && cleanupMedium) {
                            appState.cleanupEnabled = true
                            cleanupMedium = true
                        }
                    }
                }
                .padding(.top, 18)
                .overlay(alignment: .top) { Rectangle().fill(D.rule).frame(height: 1) }
                .padding(.top, 30)
            }
            .padding(.horizontal, 32)
            .padding(.top, 6)
            .padding(.bottom, 32)
        }
    }

    private func name(_ choice: StyleChoice) -> String {
        switch choice {
        case .formal: "Formal"
        case .casual: "Casual"
        case .veryCasual: "lowercase"
        case .excited: "Excited"
        }
    }

    private func cleanupOption(_ title: String, _ note: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(D.font(15)).foregroundStyle(selected ? Color.white : D.ink3)
                Text(note).font(D.font(12.5)).foregroundStyle(D.ink3).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(selected ? Color.white : D.rule).frame(height: 1.5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
