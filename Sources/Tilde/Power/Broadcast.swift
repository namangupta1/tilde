import AppKit

/// Broadcast input: keys typed into a pane of a broadcasting tab are replayed into its other panes.
/// Each peer encodes the key itself, so cursor-key modes etc. stay correct per pane.
@MainActor
enum Broadcast {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // ⌘ shortcuts belong to the menus, not the shells.
            guard !event.modifierFlags.contains(.command),
                  let tv = event.window?.firstResponder as? TildeTerminalView,
                  let peers = tv.broadcastPeers?(), !peers.isEmpty else { return event }
            for p in peers { p.keyDown(with: event) }
            return event
        }
    }
}
