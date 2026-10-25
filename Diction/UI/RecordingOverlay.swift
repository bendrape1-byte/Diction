import SwiftUI
import AppKit

enum OverlayMessage: Equatable {
    case recording
    case handsFree
    case modelLoading
    case cleaningUp
    case transcribing
    case clipboardFallback(appName: String?)
    case noSoundDetected
    case learnedCorrection(MisheardReplacement)

    var primaryText: String {
        switch self {
        case .recording, .handsFree:
            return "Listening"
        case .modelLoading:
            return "Loading the speech model"
        case .cleaningUp, .transcribing:
            return "Writing"
        case .clipboardFallback:
            return "Copied"
        case .noSoundDetected:
            return "No sound"
        case .learnedCorrection:
            return "Added to your dictionary"
        }
    }

    var secondaryText: String? {
        switch self {
        case .clipboardFallback:
            return "Press ⌘V to paste"
        case .noSoundDetected:
            return "Check your microphone in Settings"
        case .learnedCorrection(let replacement):
            return "\(replacement.wrong) → \(replacement.right)"
        default:
            return nil
        }
    }

    /// Recording and processing show the line; everything else is a short text on the plate.
    var lineMode: LinePlate.Mode? {
        switch self {
        case .recording:
            return .listening
        case .handsFree:
            return .handsFree
        case .transcribing, .cleaningUp:
            return .processing
        default:
            return nil
        }
    }
}

/// The indicator hangs under the menu bar, centered: a small Klein-blue plate, see `LinePlate`.
class RecordingOverlayController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<OverlayPillView>?
    private var dismissWorkItem: DispatchWorkItem?
    private var currentMessage: OverlayMessage?
    /// The Notes plate; it steps aside while a dictation or a notice is showing.
    private var notesPanel: NSPanel?
    var onNoSoundSettingsTapped: (() -> Void)?
    var onAlwaysAllowPaste: (() -> Void)?
    /// Live mic level 0...1 that moves the line.
    var levelProvider: () -> Float = { 0 }
    /// Esc cancels and fn finishes a hands-free dictation; a click on the plate also finishes it.
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?

    func show(message: OverlayMessage = .recording) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        notesPanel?.orderOut(nil)

        let size = panelSize(for: message)
        if let hostingView = hostingView, let panel = panel {
            hostingView.rootView = makePillView(for: message)
            panel.setContentSize(size)
            panel.ignoresMouseEvents = !isInteractive(message)
            panel.contentViewController?.view.frame = NSRect(origin: .zero, size: size)
            hostingView.frame = NSRect(origin: .zero, size: size)
            position(panel: panel)
            panel.invalidateShadow()
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            currentMessage = message
            scheduleDismissIfNeeded(for: message)
            return
        }

        let panel = Self.makePanel(size: size)
        panel.ignoresMouseEvents = !isInteractive(message)

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let hosting = NSHostingView(rootView: makePillView(for: message))
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        let contentViewController = NSViewController()
        contentViewController.view = container
        panel.contentViewController = contentViewController
        self.hostingView = hosting

        position(panel: panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        self.panel = panel
        currentMessage = message
        scheduleDismissIfNeeded(for: message)
    }

    /// Hides the plate. After writing, the line first collapses into a dot, the moment the text lands.
    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard let panel else { return }
        let landed = currentMessage?.lineMode == .processing
        if landed { hostingView?.rootView = OverlayPillView(message: .transcribing, level: { 0 }, done: true) }
        let fade = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 }) { [weak self] in
                panel.orderOut(nil)
                if self?.panel == nil { self?.notesPanel?.orderFrontRegardless() }
            }
            self?.panel = nil
            self?.hostingView = nil
            self?.currentMessage = nil
        }
        dismissWorkItem = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + (landed ? 0.24 : 0), execute: fade)
    }

    func showNotetaker(_ session: MeetingSession) {
        notesPanel?.orderOut(nil)
        let panel = Self.makePanel(size: LinePlate.size)
        panel.ignoresMouseEvents = true
        let hosting = NSHostingView(rootView: NotesPlateView(session: session))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: LinePlate.size)
        panel.contentView = hosting
        position(panel: panel)
        if self.panel == nil { panel.orderFrontRegardless() }
        notesPanel = panel
    }

    func hideNotetaker() {
        notesPanel?.orderOut(nil)
        notesPanel = nil
    }

    private static func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true  // follows the capsule, the corners stay transparent
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    func dismiss(ifShowing message: OverlayMessage) {
        guard currentMessage == message else {
            return
        }

        dismiss()
    }

    private func position(panel: NSPanel) {
        if let screen = NSScreen.main {
            let area = screen.visibleFrame  // below the menu bar (and the notch)
            panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.maxY - 8 - panel.frame.height))
        }
    }

    private func panelSize(for message: OverlayMessage) -> NSSize {
        if message.lineMode != nil { return LinePlate.size }
        let size = NSHostingView(rootView: makePillView(for: message)).fittingSize
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    private func isInteractive(_ message: OverlayMessage) -> Bool {
        if case .clipboardFallback = message { return true }
        return message == .noSoundDetected || message == .handsFree
    }

    private func makePillView(for message: OverlayMessage) -> OverlayPillView {
        OverlayPillView(
            message: message,
            onTap: message == .noSoundDetected ? { [weak self] in self?.onNoSoundSettingsTapped?() }
                : message == .handsFree ? { [weak self] in self?.onFinish?() } : nil,
            onAlwaysAllowPaste: { [weak self] in self?.onAlwaysAllowPaste?() },
            level: levelProvider
        )
    }

    private func scheduleDismissIfNeeded(for message: OverlayMessage) {
        switch message {
        case .clipboardFallback, .learnedCorrection, .noSoundDetected:
            let delay: TimeInterval
            if case .clipboardFallback = message {
                delay = 8
            } else {
                delay = message == .noSoundDetected ? 5 : 3
            }
            let workItem = DispatchWorkItem { [weak self] in
                self?.dismiss()
            }
            dismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        default:
            return
        }
    }
}

struct OverlayPillView: View {
    let message: OverlayMessage
    var onTap: (() -> Void)?
    var onAlwaysAllowPaste: (() -> Void)?
    var level: () -> Float = { 0 }
    var done = false

    var body: some View {
        if let mode = message.lineMode {
            LinePlate(mode: done ? .done : mode, level: level)
                .onTapGesture { onTap?() }
                .help(mode == .handsFree ? "Click or press fn to finish, Esc to cancel" : "")
        } else {
            notice
        }
    }

    private var notice: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(message.primaryText).font(D.font(12.5, .medium))
                if let secondaryText = message.secondaryText {
                    Text(secondaryText).font(D.font(11.5)).foregroundStyle(D.ink2).lineLimit(2)
                }
            }
            if case .clipboardFallback(let appName) = message, let appName {
                Button { onAlwaysAllowPaste?() } label: {
                    Text("Always paste in \(appName)")
                        .font(D.font(11.5, .medium))
                        .foregroundStyle(D.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .bluePill()
        .contentShape(Capsule())
        .onTapGesture { onTap?() }
    }
}

extension View {
    /// The Klein-blue capsule behind the line and the notices; the hairline edge keeps it apart from dark backgrounds.
    func bluePill() -> some View {
        background(Capsule().fill(D.blue)).overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
    }
}

/// While Notes runs: the dashed line, then the flat line with the running light while the last minutes are written.
private struct NotesPlateView: View {
    @ObservedObject var session: MeetingSession
    var body: some View {
        LinePlate(mode: session.isDraining ? .processing : .notes)
    }
}

// MARK: - The line

/// A small Klein-blue pill with one white line. It waves with your voice, gets brackets in hands-free mode,
/// goes flat with a light running along it while the text is written, collapses into a dot when the text lands,
/// and becomes a moving dashed line while Notes runs. It only moves to show what is happening.
struct LinePlate: View {
    enum Mode: Equatable { case listening, handsFree, processing, done, notes }
    /// The line is drawn on a 128 × 36 grid and shrunk by this factor: the one knob for the pill's size.
    static let scale = 0.4
    static let size = NSSize(width: (128 * scale).rounded(), height: (36 * scale).rounded())  // whole points stay sharp

    let mode: Mode
    var level: () -> Float = { 0 }
    @State private var motion = LineMotion()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, _ in
                ctx.scaleBy(x: Self.scale, y: Self.scale)
                motion.draw(in: &ctx, mode: mode, level: level(), time: context.date.timeIntervalSinceReferenceDate, still: reduceMotion)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .bluePill()
        .accessibilityLabel(mode == .notes ? "Taking notes" : mode == .processing ? "Writing" : "Listening")
    }
}

/// Keeps what the line needs between frames: the eased mic level and when the mode last changed.
/// Positions are on the 128 × 36 grid; widths are divided by the scale so the strokes stay crisp at the small size.
private final class LineMotion {
    private var level = 0.0, amplitude = 0.0, lastTime: Double?
    private var mode: LinePlate.Mode?, modeStart = 0.0, amplitudeAtChange = 0.0
    private let x0 = 22.0, x1 = 106.0, cy = 18.0, px = 1 / LinePlate.scale  // one screen point on the grid

    func draw(in ctx: inout GraphicsContext, mode: LinePlate.Mode, level target: Float, time t: Double, still: Bool) {
        if mode != self.mode {
            self.mode = mode
            modeStart = t
            amplitudeAtChange = amplitude
        }
        let frames = max(0, (t - (lastTime ?? t)) * 60)
        lastTime = t
        let keep = pow(0.82, frames)  // eases 18 % of the way to the mic level per 60 Hz frame
        level = level * keep + Double(target) * (1 - keep)
        let since = t - modeStart

        switch mode {
        case .listening, .handsFree:
            amplitude = still ? 0 : 1.4 + level * 10
            if amplitude < 0.5 {
                stroke(&ctx, line(x0, x1), width: 1.2 + level * 1.6)
            } else {
                stroke(&ctx, wave(amplitude, t))
            }
            if mode == .handsFree {  // brackets: it keeps listening on its own
                var brackets = Path()
                for (x, dir) in [(x0 - 9, 1.0), (x1 + 9, -1.0)] {
                    brackets.move(to: CGPoint(x: x + dir * 4, y: cy - 7))
                    brackets.addLine(to: CGPoint(x: x, y: cy - 7))
                    brackets.addLine(to: CGPoint(x: x, y: cy + 7))
                    brackets.addLine(to: CGPoint(x: x + dir * 4, y: cy + 7))
                }
                stroke(&ctx, brackets, width: 1.1, opacity: 0.9)
            }
        case .processing:
            amplitude = amplitudeAtChange * exp(-since / 0.11)  // the wave settles flat
            if amplitude > 0.25, !still {
                stroke(&ctx, wave(amplitude, t))
                return
            }
            stroke(&ctx, line(x0, x1), opacity: 0.45)
            let travel = still ? 0.45 : ((since - 0.16) / 0.82).truncatingRemainder(dividingBy: 1)
            let start = x0 - 16 + (x1 - x0 + 16) * max(0, travel)
            stroke(&ctx, line(max(x0, start), min(x1, start + 16)), width: 1.9)
        case .done:
            let p = still ? 1 : 1 - pow(1 - min(1, since / 0.22), 4)
            let end = x1 - (x1 - x0) * p
            if end - x0 > 1 {
                stroke(&ctx, line(x0, end))
            } else {
                let r = 1.2 * px
                ctx.fill(Path(ellipseIn: CGRect(x: x0 - r, y: cy - r, width: 2 * r, height: 2 * r)), with: .color(.white))
            }
        case .notes:
            let phase = still ? 0 : (t * 18).truncatingRemainder(dividingBy: 9)
            ctx.stroke(line(x0, x1), with: .color(.white.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 1.2 * px, lineCap: .round, dash: [5, 4], dashPhase: phase))
        }
    }

    private func line(_ a: Double, _ b: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: a, y: cy))
        p.addLine(to: CGPoint(x: b, y: cy))
        return p
    }

    private func wave(_ a: Double, _ t: Double) -> Path {
        var p = Path()
        for i in 0...56 {
            let u = Double(i) / 56, envelope = pow(sin(.pi * u), 1.2)
            let y = cy + a * envelope * (0.78 * sin(2 * .pi * u * 2.1 - t * 7.2) + 0.26 * sin(2 * .pi * u * 4.3 + t * 5.1))
            let point = CGPoint(x: x0 + (x1 - x0) * u, y: y)
            i == 0 ? p.move(to: point) : p.addLine(to: point)
        }
        return p
    }

    /// `width` in screen points.
    private func stroke(_ ctx: inout GraphicsContext, _ path: Path, width: Double = 1.3, opacity: Double = 1) {
        ctx.stroke(path, with: .color(.white.opacity(opacity)), style: StrokeStyle(lineWidth: width * px, lineCap: .round, lineJoin: .round))
    }
}
