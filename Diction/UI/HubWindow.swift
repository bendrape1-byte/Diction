import AppKit
import CoreText
import SwiftUI

// The Diction window: one Klein-blue canvas, white type, and the voice drawn as a single white line.

enum D {
    static let blue = Color(red: 0, green: 47 / 255, blue: 167 / 255)               // International Klein Blue, #002FA7
    static let raised = Color(red: 17 / 255, green: 67 / 255, blue: 179 / 255)      // hovered row
    static let ink2 = Color(red: 190 / 255, green: 210 / 255, blue: 246 / 255)      // secondary text, 7:1 on the blue
    static let ink3 = Color(red: 153 / 255, green: 181 / 255, blue: 232 / 255)      // labels and times, 5:1
    static let ink4 = Color(red: 119 / 255, green: 152 / 255, blue: 214 / 255)      // large unselected text, 3.7:1
    static let rule = Color.white.opacity(0.16)
    static let warn = Color(red: 1, green: 200 / 255, blue: 196 / 255)               // errors: pale red, 7:1 on the blue

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { atkinson(size, weight, italic: false) }
    static func italic(_ size: CGFloat) -> Font { atkinson(size, .regular, italic: true) }
    static func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }

    /// Atkinson Hyperlegible Next, from the asset catalog (SIL Open Font License, see THIRD_PARTY_NOTICES.md).
    /// It's one variable font per slant: SwiftUI's .weight() can't reach its weight axis, so the weight is set directly.
    private static var faces: [Bool: CTFontDescriptor] = [:]
    private static var cache: [String: Font] = [:]

    static func registerFonts() {
        for (italic, name) in [(false, "AtkinsonNext"), (true, "AtkinsonNextItalic")] {
            guard let data = NSDataAsset(name: name)?.data,
                  let face = (CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor])?.first else { continue }
            faces[italic] = face
        }
    }

    private static func atkinson(_ size: CGFloat, _ weight: Font.Weight, italic: Bool) -> Font {
        let wght: CGFloat = switch weight {
        case .bold: 700
        case .semibold: 600
        case .medium: 500
        default: 400
        }
        let key = "\(size)-\(wght)-\(italic)"
        if let font = cache[key] { return font }
        guard let face = faces[italic] else { return .system(size: size, weight: weight) }
        let axis = 0x7767_6874  // 'wght'
        let weighted = CTFontDescriptorCreateCopyWithAttributes(face, [kCTFontVariationAttribute: [axis: wght]] as CFDictionary)
        let font = Font(CTFontCreateWithFontDescriptor(weighted, size, nil))
        cache[key] = font
        return font
    }
}

enum HubPage: String, CaseIterable, Identifiable {
    case history, meetings, dictionary, swaps, style
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

@MainActor
final class HubWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(appState: AppState) {
        Self.applyDockPolicy()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 780),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Diction"
            w.isMovableByWindowBackground = true
            w.appearance = NSAppearance(named: .darkAqua)  // light cursors, scroll bars and menus on the blue
            w.backgroundColor = NSColor(D.blue)
            w.minSize = NSSize(width: 520, height: 560)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: HubView(appState: appState))
            w.center()
            w.setFrameAutosaveName("DictionWindow")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    /// Settings → "Show in Dock" (on by default).
    static func applyDockPolicy() {
        let showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }
}

struct HubView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var store = HubStore.shared
    @State private var page: HubPage
    @Namespace private var tabLine

    init(appState: AppState, page: HubPage = .history) {
        self.appState = appState
        _page = State(initialValue: page)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabs
            Group {
                switch page {
                case .history: HistoryPage(store: store, shortcut: appState.pushToTalkChord.displayString)
                case .meetings: NotesPage(appState: appState)
                case .dictionary: DictionaryPage(corrections: appState.correctionStore)
                case .swaps: SnippetsPage(store: store)
                case .style: StylePage(appState: appState)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(D.blue)
        .foregroundStyle(.white)
        .font(D.font(14.5))
        .tint(.white)
        .ignoresSafeArea()
    }

    /// Five words in the title bar, level with the traffic lights. A line slides under the open one.
    private var tabs: some View {
        HStack(spacing: 18) {
            ForEach(HubPage.allCases) { p in
                Button {
                    withAnimation(.timingCurve(0.25, 1, 0.5, 1, duration: 0.26)) { page = p }
                } label: {
                    Text(p.title)
                        .font(D.font(13.5))
                        .foregroundStyle(page == p ? Color.white : D.ink3)
                        .padding(.vertical, 5)
                        .overlay(alignment: .bottom) {
                            if page == p {
                                Rectangle().fill(.white).frame(height: 1.5).matchedGeometryEffect(id: "tab", in: tabLine)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button(action: appState.showSettings) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                    .foregroundStyle(D.ink3)
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings")
        }
        .padding(.leading, 90)  // right of the traffic lights
        .padding(.trailing, 12)
        .frame(height: 30)
        .padding(.bottom, 8)
    }
}

// MARK: - History

struct HistoryPage: View {
    @ObservedObject var store: HubStore
    let shortcut: String
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 28) {
                SpiralView(segments: store.spiral(size: 236))
                museumLabel.padding(.bottom, 4)
            }
            .padding(.horizontal, 32)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(D.ink3)
                TextField("Search", text: $search).textFieldStyle(.plain).font(D.font(13.5))
            }
            .padding(.top, 12)
            .overlay(alignment: .top) { Rectangle().fill(D.rule).frame(height: 1) }
            .padding(.horizontal, 32)
            .padding(.top, 18)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) { list }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
            }
        }
    }

    /// Like the label next to a painting: who, what, and the medium. The word count is the only number in the app.
    private var museumLabel: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !NSFullUserName().isEmpty { Text(NSFullUserName()).font(D.font(12.5, .bold)) }
            Text("Everything you said, \(years)").font(D.italic(12.5)).foregroundStyle(D.ink2)
            Text("Voice on Klein blue, \(store.totalWords.formatted()) words").font(D.font(12.5)).foregroundStyle(D.ink2)
        }
    }

    private var years: String {
        let now = Calendar.current.component(.year, from: Date())
        let first = store.dictations.last.map { Calendar.current.component(.year, from: $0.date) } ?? now
        return first == now ? "\(now)" : "\(first) to \(now)"
    }

    private var filtered: [DictationRecord] {
        let all = search.isEmpty ? store.dictations : store.dictations.filter { $0.text.localizedCaseInsensitiveContains(search) }
        return Array(all.prefix(300))  // ponytail: newest 300 shown, search covers all
    }

    @ViewBuilder private var list: some View {
        let shown = filtered
        if shown.isEmpty {
            Text(store.dictations.isEmpty ? "Hold \(shortcut) and talk. What you say shows up here." : "Nothing you said matches that.")
                .font(D.font(13.5))
                .foregroundStyle(D.ink3)
                .padding(.top, 18)
                .padding(.leading, 12)
        }
        let days = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.date) }
        ForEach(days.keys.sorted(by: >), id: \.self) { day in
            Text(Self.dayLabel(day))
                .font(D.font(12))
                .foregroundStyle(D.ink3)
                .padding(.top, 16)
                .padding(.bottom, 4)
                .padding(.leading, 12)
            ForEach(days[day]!) { d in
                HistoryRow(record: d) { store.deleteDictation(d) }
            }
        }
    }

    static func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let format = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        return day.formatted(cal.isDate(day, equalTo: Date(), toGranularity: .year) ? format : format.year())
    }
}

/// Click copies the text and the row flips to white for a moment; right-click offers Delete.
private struct HistoryRow: View {
    let record: DictationRecord
    let onDelete: () -> Void
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(record.date, format: .dateTime.hour().minute())
                    .font(D.mono(11.5))
                    .foregroundStyle(copied ? D.blue : D.ink3)
                    .frame(width: 44, alignment: .leading)
                Text(record.text)
                    .font(D.font(14.5))
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(copied ? "Copied" : "Copy")
                    .font(D.font(12))
                    .foregroundStyle(copied ? D.blue : D.ink2)
                    .opacity(hover || copied ? 1 : 0)
            }
            .foregroundStyle(copied ? D.blue : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(copied ? Color.white : hover ? D.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Copy", action: copy)
            Button("Delete", role: .destructive, action: onDelete)
        }
        .animation(.easeOut(duration: 0.18), value: copied)
        .animation(.easeOut(duration: 0.15), value: hover)
        .accessibilityLabel("Copy: \(record.text)")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { copied = false }
    }
}

/// Every dictation on one white spiral line (see `Spiral`), older parts fainter, a dot where the line ends.
struct SpiralView: View {
    let segments: [[CGPoint]]

    var body: some View {
        Canvas { ctx, _ in
            let n = segments.count
            for (i, points) in segments.enumerated() {
                var path = Path()
                path.addLines(points)
                ctx.opacity = 0.34 + 0.62 * pow(Double(i) / Double(max(n - 1, 1)), 1.3)
                ctx.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
            }
            if let end = segments.last?.last {
                ctx.opacity = 1
                ctx.fill(Path(ellipseIn: CGRect(x: end.x - 2.1, y: end.y - 2.1, width: 4.2, height: 4.2)), with: .color(.white))
            }
        }
        .frame(width: 236, height: 236)
        .accessibilityLabel("Every dictation drawn on one spiral line, oldest in the middle")
    }
}

// MARK: - shared pieces

/// The logo: a line that waves on the left and runs flat on the right. Same shape as the app icon.
struct LineMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for i in 0...80 {
            let u = CGFloat(i) / 80, v = u / 0.6
            let y = v < 1 ? -0.22 * pow(1 - v, 1.15) * sin(2 * .pi * 2.2 * v) : 0
            let pt = CGPoint(x: rect.minX + u * rect.width, y: rect.midY + y * rect.height)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }
}

struct WhiteButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(D.font(13.5, .medium))
                .foregroundStyle(D.blue)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct LineButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(D.font(13.5))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.5)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A text field that is only a line under the text.
struct LineField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(D.font(14.5))
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.35)).frame(height: 1) }
            .onSubmit(onSubmit)
    }
}
