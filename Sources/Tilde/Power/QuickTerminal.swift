import AppKit
import Carbon.HIToolbox

/// Global hotkeys Tilde offers for the quick terminal.
enum QuickHotkey: String, CaseIterable, Identifiable {
    case ctrlGrave, optGrave, optSpace, f12
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ctrlGrave: return "⌃`"
        case .optGrave: return "⌥`"
        case .optSpace: return "⌥Space"
        case .f12: return "F12"
        }
    }
    var keyCode: UInt32 {
        switch self {
        case .ctrlGrave, .optGrave: return UInt32(kVK_ANSI_Grave)
        case .optSpace: return UInt32(kVK_Space)
        case .f12: return UInt32(kVK_F12)
        }
    }
    var modifiers: UInt32 {
        switch self {
        case .ctrlGrave: return UInt32(controlKey)
        case .optGrave, .optSpace: return UInt32(optionKey)
        case .f12: return 0
        }
    }
}

private final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A terminal that drops down from the top of the screen on a global hotkey, from any app.
@MainActor
final class QuickTerminal: NSObject, NSWindowDelegate {
    static let shared = QuickTerminal()

    static let enabledKey = "quickTerminalEnabled"
    static let hotkeyKey = "quickTerminalHotkey"

    /// Fixed pane ID so the quick terminal's shell also survives quitting.
    static let paneID: UUID = {
        if let s = UserDefaults.standard.string(forKey: "quickTerminalPaneID"), let id = UUID(uuidString: s) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: "quickTerminalPaneID")
        return id
    }()

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var hotkey: QuickHotkey {
        UserDefaults.standard.string(forKey: hotkeyKey).flatMap(QuickHotkey.init) ?? .ctrlGrave
    }

    private var panel: QuickPanel?
    private var host: TerminalHostView?
    private var session: TerminalSession?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var previousApp: NSRunningApplication?
    private var animating = false

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: Hotkey

    /// (Re)registers the hotkey from settings.
    func start() {
        if handlerRef == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { QuickTerminal.shared.toggle() } }
                return noErr
            }, 1, &type, nil, &handlerRef)
        }
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        guard Self.enabled else { hide(); return }
        let k = Self.hotkey
        let id = EventHotKeyID(signature: OSType(0x54494C44), id: 1)   // 'TILD'
        RegisterEventHotKey(k.keyCode, k.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)

        NotificationCenter.default.addObserver(self, selector: #selector(appResigned),
                                               name: NSApplication.didResignActiveNotification, object: nil)
    }

    @objc private func appResigned() { if isVisible { hide(restoreFocus: false) } }

    // MARK: Show / hide

    func toggle() {
        if isVisible && (panel?.isKeyWindow ?? false) { hide() } else { show() }
    }

    func show() {
        guard !animating else { return }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front

        let panel = self.panel ?? makePanel()
        ensureSession()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        let h = (vf.height * 0.42).rounded()
        let target = NSRect(x: vf.minX, y: vf.maxY - h, width: vf.width, height: h)
        var start = target
        start.origin.y = vf.maxY

        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if let host { panel.makeFirstResponder(host.terminal) }
        animating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { MainActor.assumeIsolated { self.animating = false } })
    }

    func hide(restoreFocus: Bool = true) {
        guard let panel, panel.isVisible, !animating else { return }
        animating = true
        var end = panel.frame
        end.origin.y += end.height
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                self.animating = false
                if restoreFocus, let app = self.previousApp { app.activate() }
                self.previousApp = nil
            }
        })
    }

    private func makePanel() -> QuickPanel {
        let p = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
                           styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isMovable = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        container.layer?.masksToBounds = true
        p.contentView = container
        panel = p
        return p
    }

    private func ensureSession() {
        guard session == nil || session!.exited, let panel, let container = panel.contentView else { return }
        host?.removeFromSuperview()
        let s = TerminalSession(paneID: Self.paneID, directory: NSHomeDirectory())
        s.onExit = { [weak self] _ in
            DispatchQueue.main.async {
                self?.session = nil
                self?.hide()
            }
        }
        TerminalRegistry.shared.register(s)
        session = s
        let h = TerminalHostView(terminal: s.view)
        h.frame = container.bounds
        h.autoresizingMask = [.width, .height]
        container.addSubview(h)
        host = h
    }
}
