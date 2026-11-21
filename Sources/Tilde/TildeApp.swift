import AppKit
import SwiftUI

enum AppInfo {
    static let name = "Tilde"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        ThemeManager.shared.start()
        HostMonitor.shared.start()
        NotificationRouter.shared.install()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TildeApp.store.appBecameActive() }
        }
        NSWindow.allowsAutomaticWindowTabbing = false
        Broadcast.install()
        QuickTerminal.shared.start()
        SecureInput.install()
        AgentHooks.installScript()
        FolderFinder.refresh()
        // Shells left behind by panes that no longer exist.
        if PersistentSessions.available {
            var keep = Set(TildeApp.store.orderedTabs.flatMap { $0.root.allPanes.map(\.id) })
            keep.insert(QuickTerminal.paneID)
            for d in TildeApp.store.workspace.detached { for p in d.tab.root.allPanes { keep.insert(p.id) } }
            PersistentSessions.cleanup(keeping: keep)
        }
    }

    /// Set by "Quit and End All Shells".
    static var endSessionsOnQuit = false

    func applicationWillTerminate(_ notification: Notification) {
        TildeApp.store.saveNow()
        HostStore.shared.saveNow()
        let end = AppDelegate.endSessionsOnQuit || !PersistentSessions.enabled
        TerminalRegistry.shared.closeAll(endSessions: end)
        // Also tabs not opened since launch: their shells run with no session object here.
        if end { PersistentSessions.killAll() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TildeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    static let store = WorkspaceStore()
    @StateObject private var store = TildeApp.store
    @StateObject private var theme = ThemeManager.shared
    @StateObject private var hostStore = HostStore.shared
    @StateObject private var monitor = HostMonitor.shared
    @StateObject private var snippets = SnippetStore.shared

    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 400)
            } detail: {
                DetailView()
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { store.split(.horizontal) } label: { Image(systemName: "rectangle.split.2x1") }
                        .help("Split Right (⌘D)")
                    Button { store.split(.vertical) } label: { Image(systemName: "rectangle.split.1x2") }
                        .help("Split Down (⇧⌘D)")
                    Button { store.newTab() } label: { Image(systemName: "plus") }
                        .help("New Tab (⌘T)")
                }
            }
            .navigationTitle(navTitle)
            .overlay(alignment: .top) {
                if store.showPalette {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.12)
                            .ignoresSafeArea()
                            .onTapGesture { store.showPalette = false }
                        CommandPalette().padding(.top, 70)
                    }
                    .transition(.opacity)
                }
            }
            .sheet(isPresented: $store.showSnippets) {
                SnippetManager(onClose: { store.showSnippets = false })
                    .environmentObject(snippets).environmentObject(store).environmentObject(hostStore)
            }
            .sheet(isPresented: $store.showTemplates) {
                TemplateManager(onClose: { store.showTemplates = false })
                    .environmentObject(TemplateStore.shared).environmentObject(store).environmentObject(hostStore)
            }
            .sheet(isPresented: $store.showDetached) {
                DetachedSessionsView(onClose: { store.showDetached = false }).environmentObject(store)
            }
            .sheet(isPresented: $store.showSessionSearch) {
                SessionSearchView(onClose: { store.showSessionSearch = false }).environmentObject(store)
            }
            .sheet(isPresented: $store.showShortcuts) {
                ShortcutsView(onClose: { store.showShortcuts = false })
            }
            .sheet(isPresented: $store.showMultiRun) {
                MultiHostRunView(onClose: { store.showMultiRun = false })
                    .environmentObject(hostStore).environmentObject(theme)
            }
            .overlay(alignment: .bottom) {
                if let t = store.toast {
                    Text(t)
                        .font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.toast)
            .sheet(item: $store.pendingSnippet) { p in
                SnippetFillSheet(pending: p) { text, run in
                    store.pendingSnippet = nil
                    if let text { store.activeSession?.insert(text, run: run) }
                }
            }
            .frame(minWidth: 700, minHeight: 420)
            .sheet(item: $store.editingHost) { h in
                HostEditor(host: h, isNew: hostStore.host(h.id) == nil,
                           onSave: { saved in
                               hostStore.upsert(saved)
                               store.editingHost = nil
                               store.selectHost(saved.id)
                           },
                           onCancel: { store.editingHost = nil })
                    .environmentObject(theme)
            }
            .environmentObject(store)
            .environmentObject(theme)
            .environmentObject(hostStore)
            .environmentObject(monitor)
            .environmentObject(snippets)
            .preferredColorScheme(theme.mode == .system ? nil : (theme.mode == .dark ? .dark : .light))
        }
        .defaultSize(width: 1100, height: 700)
        .commands { TildeCommands(store: store, theme: theme) }

        Settings {
            SettingsView().environmentObject(theme)
        }
    }
}

extension TildeApp {
    var navTitle: String {
        if let id = store.selectedHostID, let h = hostStore.host(id) { return h.name }
        return store.selectedTab.map { store.displayTitle($0) } ?? AppInfo.name
    }
}

struct TildeCommands: Commands {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var theme: ThemeManager

    var body: some Commands {
        SidebarCommands()
        CommandGroup(after: .appSettings) {
            Toggle("Secure Keyboard Entry", isOn: Binding(
                get: { SecureInput.enabled },
                set: { UserDefaults.standard.set($0, forKey: SecureInput.key); SecureInput.update() }))
        }
        CommandGroup(after: .appTermination) {
            Button("Quit and End All Shells") {
                AppDelegate.endSessionsOnQuit = true
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { store.newTab() }.keyboardShortcut("t")
            Button("New Tab in Git Worktree…") { store.newWorktreeTab() }.keyboardShortcut("t", modifiers: [.command, .option])
            Button("New Folder") { store.addFolder() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Subfolder") { store.addSubfolderToSelected() }.keyboardShortcut("n", modifiers: [.command, .shift, .option])
            Button("Add Folder from Disk…") { store.addFolderFromDisk() }.keyboardShortcut("o")
            TemplatesMenu(store: store)
            Button("Save Folder as Template…") {
                if let i = store.selectedFolderIndex { store.promptSaveTemplate(folderID: store.workspace.folders[i].id) }
            }
            Divider()
            Button("Split Right") { store.split(.horizontal) }.keyboardShortcut("d")
            Button("Split Down") { store.split(.vertical) }.keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("New Host…") { store.editingHost = Host.blank() }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Run Command on Hosts…") { store.showMultiRun = true }.keyboardShortcut("h", modifiers: [.command, .option])
            Divider()
            Button("Detach Tab") { if let t = store.selectedTab { store.detachTab(t.id) } }
                .disabled(!PersistentSessions.available)
            Button("Detached Sessions…") { store.showDetached = true }
            Button("Reopen Closed Tab") { store.reopenClosedTab() }.keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Export Scrollback…") { if let t = store.selectedTab { store.exportTranscript(t.id) } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Close Pane") { store.closeActivePane() }.keyboardShortcut("w")
            Button("Close Tab") { if let t = store.selectedTab { store.closeTab(t.id) } }
                .keyboardShortcut("w", modifiers: [.command, .option])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { store.activeSession?.showFind() }.keyboardShortcut("f")
            Button("Find Next") { store.activeSession?.findNext() }.keyboardShortcut("g")
            Button("Find Previous") { store.activeSession?.findPrevious() }.keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Search All Sessions…") { store.showSessionSearch = true }.keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Copy Last Command Output") { store.copyLastOutput() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Open Selected File in Editor") { store.openSelectedFile() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Paste Image as File Path") { store.activeSession?.pasteImageAsPath() }.keyboardShortcut("v", modifiers: [.command, .option])
            Divider()
            Button("Clear Screen") { store.clearActive(scrollback: false) }.keyboardShortcut("l", modifiers: [.command])
            Button("Clear Scrollback") { store.clearActive(scrollback: true) }.keyboardShortcut("k", modifiers: [.command, .option])
        }
        CommandMenu("Go") {
            Button("Command Palette…") { store.showPalette.toggle() }.keyboardShortcut("k")
            Button("Command Palette (alt)") { store.showPalette.toggle() }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Jump to Tab Needing Attention") { store.jumpToAttention() }.keyboardShortcut("j")
            Divider()
            Divider()
            Button("Previous Pane") { store.cyclePane(-1) }.keyboardShortcut("[")
            Button("Next Pane") { store.cyclePane(1) }.keyboardShortcut("]")
            Button("Pane Left") { store.focusPane(.left) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Pane Right") { store.focusPane(.right) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Pane Above") { store.focusPane(.up) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Pane Below") { store.focusPane(.down) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Zoom Pane") { store.toggleZoom() }.keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("Equalize Panes") { store.equalizePanes() }.keyboardShortcut("=", modifiers: [.command, .control])
            Divider()
            Button("Previous Prompt") { store.activeSession?.jumpToPrompt(up: true) }.keyboardShortcut(.upArrow)
            Button("Next Prompt") { store.activeSession?.jumpToPrompt(up: false) }.keyboardShortcut(.downArrow)
            Divider()
            Button("Snippets…") { store.showSnippets = true }.keyboardShortcut("s", modifiers: [.command, .option])
            Button("Quick Terminal") { QuickTerminal.shared.toggle() }
        }
        CommandMenu("Tab") {
            Button("Rename Tab") { NotificationCenter.default.post(name: .renameCurrentTab, object: nil) }
                .keyboardShortcut("r")
            Button("Toggle Notes") {
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "showNotes"), forKey: "showNotes")
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            Menu("Color") {
                ForEach(TabColor.allCases) { c in
                    Button(c.label) { if let t = store.selectedTab { store.setColor(t.id, c) } }
                }
            }
            Button("Duplicate Tab") { if let t = store.selectedTab { store.duplicateTab(t.id) } }
            Toggle("Broadcast Input to All Panes", isOn: Binding(
                get: { store.selectedTab?.broadcast ?? false }, set: { _ in store.toggleBroadcast() }))
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Export Transcript…") { if let t = store.selectedTab { store.exportTranscript(t.id) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Restart / Reconnect Pane") { store.restartActivePane() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Move Tab Up") { store.moveSelectedTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift, .control])
            Button("Move Tab Down") { store.moveSelectedTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift, .control])
            Button("Previous Tab") { store.cycleTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab") { store.cycleTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Divider()
            ForEach(0..<9, id: \.self) { i in
                Button(i == 8 ? "Last Tab" : "Tab \(i + 1)") { store.selectTab(atFlatIndex: i) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { store.showShortcuts = true }.keyboardShortcut("/")
        }
        CommandGroup(after: .toolbar) {
            Button("Bigger Text") { theme.bumpFont(1) }.keyboardShortcut("=")
            Button("Smaller Text") { theme.bumpFont(-1) }.keyboardShortcut("-")
            Button("Default Text Size") { theme.fontSize = 13 }.keyboardShortcut("0")
            Divider()
            Picker("Appearance", selection: $theme.modeRaw) {
                ForEach(AppearanceMode.allCases) { Text($0.label).tag($0.rawValue) }
            }
        }
    }
}
