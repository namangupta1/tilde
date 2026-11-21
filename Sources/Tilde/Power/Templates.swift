import SwiftUI

/// A saved folder layout: tabs, splits, directories, hosts and a startup command per pane.
struct WorkspaceTemplate: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var directory: String?
    var tabs: [TerminalTab]
}

extension PaneNode {
    /// Same layout with fresh pane IDs (returns the old→new ID map too).
    func withFreshIDs() -> (PaneNode, [UUID: UUID]) {
        var map: [UUID: UUID] = [:]
        func go(_ n: PaneNode) -> PaneNode {
            switch n {
            case .leaf(var p):
                let new = UUID()
                map[p.id] = new
                p.id = new
                return .leaf(p)
            case .split(let a, let c):
                return .split(axis: a, children: c.map(go))
            }
        }
        return (go(self), map)
    }
}

@MainActor
final class TemplateStore: ObservableObject {
    static let shared = TemplateStore()
    @Published var templates: [WorkspaceTemplate] = [] { didSet { save() } }

    static let fileURL = WorkspaceStore.fileURL.deletingLastPathComponent().appendingPathComponent("templates.json")

    init() {
        if let d = try? Data(contentsOf: Self.fileURL), let t = try? JSONDecoder().decode([WorkspaceTemplate].self, from: d) {
            templates = t
        }
    }

    func template(_ id: UUID) -> WorkspaceTemplate? { templates.first { $0.id == id } }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(templates) { try? d.write(to: Self.fileURL, options: .atomic) }
    }
}

extension WorkspaceStore {
    /// Captures a folder as a template. A command still running in a pane (e.g. a dev server)
    /// becomes that pane's startup command.
    func saveTemplate(fromFolder id: UUID, name: String) {
        guard let folder = snapshotDirectories().folders.first(where: { $0.id == id }) else { return }
        let tabs = folder.tabs.map { t -> TerminalTab in
            var copy = t
            for p in t.root.allPanes {
                let running = TerminalRegistry.shared.existing(p.id)?.runningCommand?.command
                copy.root = copy.root.updatingPane(p.id) { $0.startupCommand = running }
            }
            copy.broadcast = false
            return copy
        }
        let tpl = WorkspaceTemplate(name: name, directory: folder.directory, tabs: tabs)
        TemplateStore.shared.templates.append(tpl)
    }

    /// Creates a new folder from a template and selects its first tab.
    func openTemplate(_ tpl: WorkspaceTemplate) {
        var folder = Folder(name: tpl.name, directory: tpl.directory)
        folder.tabs = tpl.tabs.map { t in
            var tab = t
            let (root, map) = t.root.withFreshIDs()
            tab.id = UUID()
            tab.root = root
            tab.activePaneID = map[t.activePaneID] ?? root.allPanes.first!.id
            return tab
        }
        if folder.tabs.isEmpty { folder.tabs = [TerminalTab(directory: tpl.directory)] }
        workspace.folders.append(folder)
        select(folder.tabs[0].id)
    }

    /// Asks for a name, then saves the folder as a template.
    func promptSaveTemplate(folderID: UUID) {
        guard let folder = workspace.folders.first(where: { $0.id == folderID }) else { return }
        let alert = NSAlert()
        alert.messageText = "Save “\(folder.name)” as a template"
        alert.informativeText = "Saves its tabs, splits, directories and hosts. Commands running right now (like a dev server) start again when you open the template."
        let field = NSTextField(string: folder.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        saveTemplate(fromFolder: folderID, name: name.isEmpty ? folder.name : name)
    }
}

// MARK: - Manager

struct TemplateManager: View {
    @EnvironmentObject var templates: TemplateStore
    @EnvironmentObject var store: WorkspaceStore
    @State private var selection: UUID?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                List(selection: $selection) {
                    ForEach(templates.templates) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name)
                            Text("\(t.tabs.count) tab\(t.tabs.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(t.id)
                    }
                    .onMove { templates.templates.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minWidth: 180, idealWidth: 200)

                Group {
                    if let i = templates.templates.firstIndex(where: { $0.id == selection }) {
                        TemplateEditor(template: $templates.templates[i])
                    } else {
                        Text(templates.templates.isEmpty
                             ? "No templates yet.\nRight-click a folder ▸ Save as Template…"
                             : "Select a template.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 380)
            }
            Divider()
            HStack {
                Button {
                    let name = templates.template(selection ?? UUID())?.name ?? ""
                    guard Confirm.ask("Delete template “\(name)”?", "This can’t be undone. Folders opened from it are not affected.", confirm: "Delete") else { return }
                    templates.templates.removeAll { $0.id == selection }
                    selection = nil
                } label: { Label("Delete Template", systemImage: "minus").labelStyle(.iconOnly) }
                    .help("Delete Template")
                    .disabled(selection == nil)
                Spacer()
                Button("Open") {
                    if let t = templates.template(selection ?? UUID()) { onClose(); store.openTemplate(t) }
                }
                .disabled(selection == nil)
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 700, height: 460)
        .onExitCommand(perform: onClose)
        .onAppear { selection = selection ?? templates.templates.first?.id }
    }
}

struct TemplateEditor: View {
    @Binding var template: WorkspaceTemplate
    @EnvironmentObject var hostStore: HostStore

    var body: some View {
        Form {
            TextField("Name", text: $template.name)
            TextField("Folder directory", text: Binding(get: { template.directory ?? "" },
                                                         set: { template.directory = $0.isEmpty ? nil : $0 }))
                .font(.body.monospaced())
            ForEach(template.tabs.indices, id: \.self) { ti in
                Section(tabTitle(ti)) {
                    TextField("Tab name", text: Binding(get: { template.tabs[ti].customTitle ?? "" },
                                                        set: { template.tabs[ti].customTitle = $0.isEmpty ? nil : $0 }))
                    let panes = template.tabs[ti].root.allPanes
                    ForEach(Array(panes.enumerated()), id: \.element.id) { pi, pane in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(paneLabel(pane, index: pi, count: panes.count)).font(.caption).foregroundStyle(.secondary)
                            TextField("Startup command (optional)", text: Binding(
                                get: { pane.startupCommand ?? "" },
                                set: { v in
                                    template.tabs[ti].root = template.tabs[ti].root.updatingPane(pane.id) {
                                        $0.startupCommand = v.isEmpty ? nil : v
                                    }
                                }))
                                .font(.body.monospaced())
                        }
                    }
                    Button("Remove Tab", role: .destructive) { template.tabs.remove(at: ti) }
                        .disabled(template.tabs.count <= 1)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func tabTitle(_ i: Int) -> String {
        let t = template.tabs[i]
        let n = t.root.allPanes.count
        return "Tab \(i + 1)" + (n > 1 ? " · \(n) panes" : "")
    }

    private func paneLabel(_ p: Pane, index: Int, count: Int) -> String {
        var parts: [String] = []
        if count > 1 { parts.append("Pane \(index + 1)") }
        if let c = p.connection, let h = hostStore.host(c.hostID) {
            if case .ssh = c { parts.append("SSH \(h.name)") } else { parts.append("\(h.name) env") }
        } else if let d = p.lastDirectory {
            parts.append(d.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        }
        return parts.joined(separator: " — ")
    }
}
