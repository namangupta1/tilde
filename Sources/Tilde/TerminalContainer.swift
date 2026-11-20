import AppKit
import SwiftUI

extension Notification.Name {
    static let focusActiveTerminal = Notification.Name("TildeFocusActiveTerminal")
}

/// Hosts a long-lived terminal NSView inside SwiftUI with padding and theme background.
final class TerminalHostView: NSView {
    let terminal: TildeTerminalView
    static let padding: CGFloat = 6

    init(terminal: TildeTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        adopt()
        updateBackground()
        NotificationCenter.default.addObserver(self, selector: #selector(updateBackground), name: .terminalThemeChanged, object: nil)
        // Clicks go straight to the terminal view, so watch for them to track the active pane.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window === self.window, self.window != nil {
                let p = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(p) { self.terminal.onFocus?() }
            }
            return event
        }
    }

    private var clickMonitor: Any?

    required init?(coder: NSCoder) { fatalError() }
    deinit {
        NotificationCenter.default.removeObserver(self)
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
    }

    func adopt() {
        if terminal.superview !== self {
            terminal.removeFromSuperview()
            addSubview(terminal)
            terminal.needsDisplay = true
        }
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        terminal.needsDisplay = true
    }

    override func layout() {
        super.layout()
        terminal.frame = bounds.insetBy(dx: Self.padding, dy: Self.padding / 2)
    }

    @objc func updateBackground() {
        layer?.backgroundColor = ThemeManager.shared.palette.background.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(terminal)
    }
}

struct TerminalContainer: NSViewRepresentable {
    let pane: Pane
    let tabID: UUID
    let isActive: Bool
    @EnvironmentObject var store: WorkspaceStore

    final class Coordinator {
        var wasActive = false
        var observer: NSObjectProtocol?
        deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalHostView {
        let session = TerminalRegistry.shared.session(for: pane)
        let host = TerminalHostView(terminal: session.view)
        session.ownerHost = host
        wire(session)
        let hadStartup = pane.startupCommand != nil
        DispatchQueue.main.async { [weak store] in
            store?.titleTick &+= 1
            // A template's startup command runs once; don't repeat it on the next launch.
            if hadStartup { store?.clearStartupCommand(pane.id) }
        }
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .focusActiveTerminal, object: nil, queue: .main) { [weak host] _ in
            guard let host, store.selectedTab?.activePaneID == pane.id else { return }
            host.window?.makeFirstResponder(host.terminal)
        }
        context.coordinator.wasActive = isActive
        if isActive { focus(host) }
        return host
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        guard let s = TerminalRegistry.shared.existing(pane.id) else { return }
        // A stale host (being replaced after a layout change) must not steal the terminal back.
        if s.ownerHost === host || s.ownerHost == nil {
            s.ownerHost = host
            host.adopt()
        }
        wire(s)
        if isActive && !context.coordinator.wasActive { focus(host) }
        context.coordinator.wasActive = isActive
    }

    static func dismantleNSView(_ host: TerminalHostView, coordinator: Coordinator) {
        // Only detach if no other host has adopted the terminal already.
        if host.terminal.superview === host { host.terminal.removeFromSuperview() }
        for s in TerminalRegistry.shared.sessions.values where s.ownerHost === host { s.ownerHost = nil }
    }

    private func wire(_ session: TerminalSession) {
        let store = self.store
        let tabID = self.tabID
        let paneID = pane.id
        session.onChange = { [weak store] in store?.titleTick &+= 1 }
        session.onExit = { [weak store] code in store?.paneExited(paneID, exitCode: code) }
        session.onCommandFinished = { [weak store] rec in store?.commandFinished(paneID: paneID, record: rec) }
        session.onAttention = { [weak store] title, body in store?.paneWantsAttention(paneID: paneID, title: title, body: body) }
        session.onToast = { [weak store] text in store?.showToast(text, seconds: text.hasSuffix("…") ? 600 : 5) }
        session.view.broadcastPeers = { [weak store] in store?.broadcastPeers(of: paneID) ?? [] }
        session.onFocus = { [weak store] in
            DispatchQueue.main.async { store?.setActivePane(paneID, inTab: tabID) }
        }
    }

    private func focus(_ host: TerminalHostView) {
        DispatchQueue.main.async {
            guard let w = host.window else {
                // Not in a window yet; retry shortly.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { host.window?.makeFirstResponder(host.terminal) }
                return
            }
            w.makeFirstResponder(host.terminal)
        }
    }
}

/// Recursively renders a tab's split tree.
struct PaneTreeView: View {
    let node: PaneNode
    let tab: TerminalTab
    @EnvironmentObject var store: WorkspaceStore

    var body: some View {
        switch node {
        case .leaf(let pane):
            let multi = tab.root.allPanes.count > 1
            let active = pane.id == tab.activePaneID
            let broadcasting = tab.broadcast && multi
            TerminalContainer(pane: pane, tabID: tab.id, isActive: active)
                .overlay(
                    Rectangle()
                        .strokeBorder(broadcasting ? Color.orange.opacity(active ? 0.9 : 0.55)
                                                   : Color.accentColor.opacity(multi && active ? 0.7 : 0),
                                      lineWidth: broadcasting ? 2 : 1.5)
                        .allowsHitTesting(false)
                )
                .id(pane.id)
        case .split(let axis, let children):
            SplitContainer(axis: axis, children: children, tab: tab)
        }
    }
}

/// Equal-by-default split with draggable dividers.
struct SplitContainer: View {
    let axis: SplitAxis
    let children: [PaneNode]
    let tab: TerminalTab
    @State private var fractions: [CGFloat] = []
    @State private var dragStart: [CGFloat]?

    private let dividerThickness: CGFloat = 1
    private let minFraction: CGFloat = 0.1

    var body: some View {
        GeometryReader { geo in
            let total = (axis == .horizontal ? geo.size.width : geo.size.height) - dividerThickness * CGFloat(children.count - 1)
            let fr = normalized
            let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(Array(children.enumerated()), id: \.element.nodeID) { i, child in
                    PaneTreeView(node: child, tab: tab)
                        .frame(width: axis == .horizontal ? max(0, total * fr[i]) : nil,
                               height: axis == .vertical ? max(0, total * fr[i]) : nil)
                    if i < children.count - 1 {
                        divider(index: i, total: total)
                    }
                }
            }
        }
        .onChange(of: children.count) { _, _ in fractions = [] }
    }

    private var normalized: [CGFloat] {
        if fractions.count == children.count { return fractions }
        return Array(repeating: 1 / CGFloat(children.count), count: children.count)
    }

    private func divider(index i: Int, total: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: axis == .horizontal ? dividerThickness : nil,
                   height: axis == .vertical ? dividerThickness : nil)
            .overlay(
                Color.clear
                    .frame(width: axis == .horizontal ? 8 : nil, height: axis == .vertical ? 8 : nil)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
                        else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                let start = dragStart ?? normalized
                                if dragStart == nil { dragStart = start }
                                guard total > 0 else { return }
                                let delta = (axis == .horizontal ? v.translation.width : v.translation.height) / total
                                let pair = start[i] + start[i + 1]
                                let a = min(max(start[i] + delta, minFraction), pair - minFraction)
                                var f = start
                                f[i] = a
                                f[i + 1] = pair - a
                                fractions = f
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            )
            .zIndex(1)
    }
}
