import AppKit
import QuartzCore
import SwiftUI

final class HUDModel: ObservableObject {
    @Published var title = ""
    @Published var body = ""
    @Published var footer = ""
    @Published var level: Float = -80
    @Published var tint: Color = .orange
    @Published var icon = "mic.fill"
    @Published var showMeter = true
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {           // icon stays at the top while the transcript grows
            ZStack {
                Circle().fill(model.tint.opacity(0.18)).frame(width: 40, height: 40)
                Image(systemName: model.icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(model.tint)
                    .transaction { $0.animation = nil }
            }
            .animation(.easeInOut(duration: 0.2), value: model.tint)
            VStack(alignment: .leading, spacing: 8) {
                // Label and meter, centered against the icon; the transcript flows below them.
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                        .transaction { $0.animation = nil }      // label swaps instantly; no blending of two words
                    if model.showMeter {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.1))
                                Capsule().fill(model.tint)
                                    .frame(width: geo.size.width * CGFloat(max(0, min(1, (model.level + 60) / 54))))
                                    .animation(.linear(duration: 0.03), value: model.level)
                            }
                        }.frame(width: 150, height: 6)
                    }
                }
                .frame(minHeight: 40, alignment: .leading)
                if !model.body.isEmpty {
                    // Live transcript, all of it: the bar grows downward as the text gets longer.
                    Text(model.body)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .transaction { $0.animation = nil }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: model.body.isEmpty ? 260 : 400, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
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
    private var suppressPartials = false

    init() {
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 70), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        panel.alphaValue = 0
    }

    private var restFrame = NSRect.zero
    private var hiddenFrame = NSRect.zero

    /// Resting position: top center, just under the menu bar. Hidden position: fully above the screen edge.
    private func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 260, height: 70)
        let frame = screen.visibleFrame
        restFrame = NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 10, width: size.width, height: size.height)
        hiddenFrame = restFrame.offsetBy(dx: 0, dy: size.height + 24)
    }

    func show() {
        guard Settings.shared.hudEnabled else { return }
        hideWork?.cancel()
        guard panel.alphaValue < 1 || !panel.isVisible else { refit(); return }   // already on screen: change in place
        place()
        panel.setFrame(hiddenFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(restFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }


    /// Resizes the visible panel to its content (the transcript grows and shrinks it), keeping it top-centered.
    private func refit() {
        guard panel.isVisible, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        guard let size = panel.contentView?.fittingSize, size != panel.frame.size else { return }
        let frame = screen.visibleFrame
        restFrame = NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 10, width: size.width, height: size.height)
        hiddenFrame = restFrame.offsetBy(dx: 0, dy: size.height + 24)
        panel.setFrame(restFrame, display: true)
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.panel.isVisible else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.panel.animator().setFrame(self.hiddenFrame, display: true)
                self.panel.animator().alphaValue = 0
            }) { self.panel.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Handle released, transcript being finalized and typed: same toast, new label.
    func listening(target: String) {
        suppressPartials = false
        model.title = "Listening"
        model.body = ""
        model.tint = .yellow
        model.icon = "mic.fill"
        model.showMeter = true
        model.level = -60
        show()
    }

    /// Claude's dictation is being started: the bar says so until Claude listens.
    func starting() {
        guard model.title.hasPrefix("Listening") else { return }
        model.title = "Starting…"
    }

    func listeningReady() {
        guard model.title == "Starting…" else { return }
        model.title = "Listening"
    }

    /// The live transcript while the handle is squeezed (and while the message is being finalized).
    func partial(_ text: String) {
        guard Settings.shared.hudTranscript, !suppressPartials,
              model.title.hasPrefix("Listening") || model.title.hasSuffix("…") else { return }
        guard text != model.body else { return }
        model.body = text
        refit()
    }

    /// Queue or draft chosen with a mic button during the squeeze: shown next to "Listening".
    func mode(_ label: String) {
        guard model.title.hasPrefix("Listening") else { return }
        model.title = "Listening · \(label)"
        model.tint = label == "Queue" ? .orange : .blue
        model.icon = label == "Queue" ? "clock" : "square.and.pencil"
    }

    /// The message is being finalized: "Sending…", "Adding to draft…" or "Queueing…".
    func sending(_ label: String = "Sending…") {
        model.title = label
        model.icon = "arrow.up"
        model.level = -60
        show()
        hide(after: 6)                         // watchdog in case delivery never reports back
    }

    func sent(_ text: String, outcome: String, title: String = "Sent") {
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
        model.body = ""
        model.tint = .gray
        model.icon = "xmark.circle"
        model.level = -60
        show()
        hide(after: 0.8)
    }

    func flash(_ message: String, detail: String = "", tint: Color = .gray, icon: String = "info.circle", seconds: TimeInterval = 1.6) {
        model.title = message
        model.body = ""
        model.tint = tint
        model.icon = icon
        model.level = -60
        show()
        hide(after: seconds)
    }
}
