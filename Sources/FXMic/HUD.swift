import AppKit
import QuartzCore
import SwiftUI

final class HUDModel: ObservableObject {
    @Published var title = ""
    @Published var body = ""
    /// The Claude conversation the message goes to, shown under the meter; empty hides the line.
    @Published var footer = ""
    @Published var level: Float = -80
    @Published var tint: Color = .orange
    @Published var icon = "mic.fill"
    @Published var showMeter = true
    /// Claude's dictation is starting: a spinner in place of the icon, and no meter (nothing is being heard yet).
    @Published var loading = false
    /// On screen: the island slides down into place when true, up and out when false.
    @Published var shown = false
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    /// Width of the island without and with a transcript. The window around it is a fixed transparent canvas, so
    /// every size change is animated here rather than by resizing the window.
    static let narrow: CGFloat = 260
    static let wide: CGFloat = 400

    var body: some View {
        HStack(alignment: .top, spacing: 14) {           // icon stays at the top while the transcript grows
            ZStack {
                Circle().fill(model.tint.opacity(0.18)).frame(width: 40, height: 40)
                if model.loading {
                    ProgressView().controlSize(.small).transition(.opacity)
                } else {
                    Image(systemName: model.icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(model.tint)
                        .contentTransition(.identity)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.tint)
            VStack(alignment: .leading, spacing: 8) {
                // Label and meter, centered against the icon; the transcript flows below them.
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                        .contentTransition(.identity)       // label swaps instantly; no blending of two words
                    if model.showMeter && !model.loading {
                        // The meter runs the full width of the island, narrow or wide.
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.1))
                                Capsule().fill(model.tint)
                                    .frame(width: geo.size.width * CGFloat(max(0, min(1, (model.level + 60) / 54))))
                                    .animation(.linear(duration: 0.03), value: model.level)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 6)
                        .transition(.opacity)
                    }
                    if !model.footer.isEmpty {
                        // Where the message goes: one line, cut at the end when the title is long.
                        HStack(spacing: 5) {
                            Image(systemName: "bubble.left.fill").font(.system(size: 9, weight: .semibold))
                            Text(model.footer).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.tail)
                                .contentTransition(.identity)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                    }
                }
                .frame(minHeight: 40, alignment: .leading)
                if !model.body.isEmpty {
                    // Live transcript, all of it: the island grows downward as the text gets longer.
                    Text(model.body)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.identity)       // new words appear in place, no crossfade
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: model.body.isEmpty ? Self.narrow : Self.wide, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        // Width when the transcript starts or ends, height as it grows: both eased, never instant.
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: model.body.isEmpty)
        .animation(.easeOut(duration: 0.18), value: model.body)
        .animation(.easeInOut(duration: 0.18), value: model.showMeter)
        .animation(.easeInOut(duration: 0.2), value: model.loading)
        .animation(.easeInOut(duration: 0.18), value: model.footer)
        .animation(.easeInOut(duration: 0.25), value: model.tint)
        .offset(y: model.shown ? 0 : -110)
        .opacity(model.shown ? 1 : 0)
    }
}

/// The transparent canvas the island moves and resizes in, top-centered.
struct HUDCanvas: View {
    @ObservedObject var model: HUDModel
    var body: some View {
        HUDView(model: model)
            .padding(.top, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Floating, click-through status panel at the top center of the screen. Never takes focus.
final class HUDController {
    let model = HUDModel()
    private let panel: HUDPanel
    private var hideWork: DispatchWorkItem?
    private var lastPartial = ""
    private var target = ""
    /// Queue or draft pressed while still "Starting…": shown once Claude listens.
    private var pendingMode: String?
    private var suppressPartials = false

    init() {
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 70), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false             // the island draws its own shadow; the window is a transparent canvas
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDCanvas(model: model))
    }

    /// The canvas: wide enough for the wide island and its shadow, tall enough for a long transcript, its top at the
    /// top of the visible screen. Transparent and click-through, so its empty part is invisible.
    private func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let width = HUDView.wide + 60
        let height = (frame.height * 0.6).rounded()
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height), display: false)
    }

    func show() {
        guard Settings.shared.hudEnabled else { return }
        hideWork?.cancel()
        if panel.isVisible, model.shown { return }       // already on screen: SwiftUI animates the change in place
        if !panel.isVisible {
            place()
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { model.shown = false }
            panel.orderFrontRegardless()
        }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { self.model.shown = true }
        }
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.panel.isVisible else { return }
            withAnimation(.easeIn(duration: 0.16)) { self.model.shown = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if !self.model.shown { self.panel.orderOut(nil) }     // unless it was shown again meanwhile
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Handle released, transcript being finalized and typed: same toast, new label.
    /// `target`: the conversation the message will go to, when already known; nil leaves the line off until it is.
    func listening(target: String?) {
        suppressPartials = false
        pendingMode = nil
        model.loading = false
        model.title = "Listening"
        model.body = ""
        model.footer = target ?? ""
        model.tint = .yellow
        model.icon = "mic.fill"
        model.showMeter = true
        model.level = -60
        show()
    }

    /// FXMic could not open the input for this squeeze, so there is no level to show: the meter goes, Claude's live
    /// text stays.
    func hideMeter() {
        guard model.title.hasPrefix("Listening") || model.title == "Starting…" else { return }
        model.showMeter = false
    }

    /// Claude's dictation is being started: grey and "Starting…" until Claude listens, so nobody talks too early.
    func starting() {
        guard model.title.hasPrefix("Listening") else { return }
        model.title = "Starting…"
        model.tint = .gray
        model.icon = "mic"
        model.loading = true
    }

    /// Claude is listening (or the fallback took over): yellow, and the conversation it is listening in.
    func listeningReady(session: String? = nil) {
        if let session, !session.isEmpty { model.footer = session }
        guard model.title == "Starting…" else { return }
        model.loading = false
        model.title = "Listening"
        model.tint = .yellow
        model.icon = "mic.fill"
        if let label = pendingMode { pendingMode = nil; mode(label) }
    }

    /// The live transcript while the handle is squeezed (and while the message is being finalized).
    func partial(_ text: String) {
        guard Settings.shared.hudTranscript, !suppressPartials,
              model.title.hasPrefix("Listening") || model.title.hasSuffix("…") else { return }
        guard text != model.body else { return }
        model.body = text
    }

    /// Queue or draft chosen with a mic button during the squeeze: shown next to "Listening".
    func mode(_ label: String) {
        if model.title == "Starting…" { pendingMode = label; return }
        guard model.title.hasPrefix("Listening") else { return }
        model.title = "Listening · \(label)"
        model.tint = label == "Queue" ? .orange : .blue
        model.icon = label == "Queue" ? "clock" : "square.and.pencil"
    }

    /// The message is being finalized: "Sending…", "Adding to draft…" or "Queueing…".
    func sending(_ label: String = "Sending…") {
        model.loading = false
        model.title = label
        model.icon = "arrow.up"
        model.level = -60
        show()
        hide(after: 6)                         // watchdog in case delivery never reports back
    }

    func sent(_ text: String, outcome: String, title: String = "Sent") {
        model.loading = false
        model.title = title
        model.body = Settings.shared.hudTranscript ? text : ""   // the final text, briefly
        model.tint = .green
        model.icon = "checkmark.circle.fill"
        model.level = -60
        show()
        hide(after: model.body.isEmpty ? 0.8 : 1.6)
    }

    func canceled() {
        suppressPartials = true
        model.title = "Canceled"
        model.loading = false
        model.body = ""
        model.footer = ""
        model.tint = .gray
        model.icon = "xmark.circle"
        model.showMeter = false          // nothing is being heard any more
        model.level = -60
        show()
        hide(after: 0.8)
    }

    func flash(_ message: String, detail: String = "", tint: Color = .gray, icon: String = "info.circle", seconds: TimeInterval = 1.6) {
        model.title = message
        model.loading = false
        model.body = ""
        model.footer = ""
        model.tint = tint
        model.icon = icon
        model.level = -60
        show()
        hide(after: seconds)
    }
}
