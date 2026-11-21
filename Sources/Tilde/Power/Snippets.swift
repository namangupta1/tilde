import SwiftUI

/// A saved command. `{{name}}` or `{{name:default}}` become fill-in fields before inserting.
struct Snippet: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var command: String
    var notes: String = ""
    /// Press Return after inserting.
    var runImmediately = false
    /// nil = available everywhere; otherwise only shown for tabs in this folder / connected to this host.
    var folderID: UUID?
    var hostID: UUID?

    struct Placeholder: Hashable, Identifiable {
        var id: String { name }
        var name: String
        var defaultValue: String
    }

    private struct Token {
        var raw: String
        var name: String
        var defaultValue: String
    }

    private static let regex = try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-z0-9_\- ]+?)\s*(?::([^}]*))?\}\}"#)

    private static func tokens(in s: String) -> [Token] {
        let ns = s as NSString
        return regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            let raw = ns.substring(with: m.range)
            let name = ns.substring(with: m.range(at: 1))
            let def = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
            return Token(raw: raw, name: name, defaultValue: def)
        }
    }

    /// Unique placeholders in order of appearance.
    var placeholders: [Placeholder] {
        var seen = Set<String>(), out: [Placeholder] = []
        for t in Self.tokens(in: command) where !seen.contains(t.name) {
            seen.insert(t.name)
            out.append(Placeholder(name: t.name, defaultValue: t.defaultValue))
        }
        return out
    }

    func filled(_ values: [String: String]) -> String {
        var result = command
        for t in Self.tokens(in: command) {
            let v = values[t.name].flatMap { $0.isEmpty ? nil : $0 } ?? t.defaultValue
            result = result.replacingOccurrences(of: t.raw, with: v)
        }
        return result
    }
}

struct PendingSnippet: Identifiable {
    let id = UUID()
    var snippet: Snippet
}

@MainActor
final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()
    @Published var snippets: [Snippet] = [] { didSet { save() } }

    static let fileURL = WorkspaceStore.fileURL.deletingLastPathComponent().appendingPathComponent("snippets.json")

    init() {
        if let d = try? Data(contentsOf: Self.fileURL), let s = try? JSONDecoder().decode([Snippet].self, from: d) {
            snippets = s
        } else {
            snippets = [
                Snippet(name: "Find large files", command: "du -ah {{path:.}} | sort -rh | head -{{count:20}}"),
                Snippet(name: "Port in use", command: "lsof -nP -iTCP:{{port}} -sTCP:LISTEN"),
                Snippet(name: "Git: recent branches", command: "git branch --sort=-committerdate | head -10", runImmediately: true),
                Snippet(name: "Tail log", command: "tail -f {{file}}"),
            ]
        }
    }

    /// Snippets that apply to a tab (global + its folder + its host).
    func available(folderID: UUID?, hostID: UUID?) -> [Snippet] {
        snippets.filter { s in
            (s.folderID == nil || s.folderID == folderID) && (s.hostID == nil || s.hostID == hostID)
        }
    }

    func add(_ s: Snippet) { snippets.append(s) }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(snippets) { try? d.write(to: Self.fileURL, options: .atomic) }
    }
}

extension WorkspaceStore {
    /// Inserts a snippet into the active pane, asking for placeholder values first when needed.
    func useSnippet(_ s: Snippet) {
        if s.placeholders.isEmpty {
            activeSession?.insert(s.command, run: s.runImmediately)
        } else {
            pendingSnippet = PendingSnippet(snippet: s)
        }
    }

    var activeFolderID: UUID? { selectedFolderIndex.map { workspace.folders[$0].id } }
    var activeHostID: UUID? { selectedTab.flatMap { host(for: $0)?.id } }
}

// MARK: - Placeholder sheet

struct SnippetFillSheet: View {
    let pending: PendingSnippet
    let onDone: (String?, Bool) -> Void
    @State private var values: [String: String] = [:]
    @FocusState private var focused: String?

    var body: some View {
        let s = pending.snippet
        VStack(alignment: .leading, spacing: 14) {
            Text(s.name).font(.headline)
            ForEach(s.placeholders) { p in
                LabeledContent(p.name) {
                    TextField(p.defaultValue.isEmpty ? p.name : p.defaultValue,
                              text: Binding(get: { values[p.name] ?? "" }, set: { values[p.name] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .focused($focused, equals: p.name)
                        .onSubmit { onDone(s.filled(values), true) }
                }
            }
            Text(s.filled(values))
                .font(.callout.monospaced())
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil, false) }.keyboardShortcut(.cancelAction)
                Button("Insert") { onDone(s.filled(values), false) }
                Button("Run") { onDone(s.filled(values), true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { focused = s.placeholders.first?.name }
    }
}

// MARK: - Manager

struct SnippetManager: View {
    @EnvironmentObject var snippets: SnippetStore
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var hostStore: HostStore
    @State private var selection: UUID?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                List(selection: $selection) {
                    ForEach(snippets.snippets) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name.isEmpty ? "Untitled" : s.name)
                            Text(s.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(s.id)
                    }
                    .onMove { snippets.snippets.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minWidth: 200, idealWidth: 220)

                Group {
                    if let i = snippets.snippets.firstIndex(where: { $0.id == selection }) {
                        SnippetEditor(snippet: $snippets.snippets[i])
                    } else {
                        Text("Select or add a snippet.\nUse {{name}} or {{name:default}} for fill-in fields.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 340)
            }
            Divider()
            HStack {
                Button { add() } label: { Image(systemName: "plus") }
                Button {
                    snippets.snippets.removeAll { $0.id == selection }
                    selection = nil
                } label: { Image(systemName: "minus") }.disabled(selection == nil)
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 680, height: 440)
        .onAppear { selection = selection ?? snippets.snippets.first?.id }
    }

    private func add() {
        let s = Snippet(name: "New snippet", command: "")
        snippets.add(s)
        selection = s.id
    }
}

struct SnippetEditor: View {
    @Binding var snippet: Snippet
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var hostStore: HostStore

    var body: some View {
        Form {
            TextField("Name", text: $snippet.name)
            TextField("Command", text: $snippet.command, axis: .vertical)
                .font(.body.monospaced())
                .lineLimit(2...6)
            if !snippet.placeholders.isEmpty {
                LabeledContent("Fields") {
                    Text(snippet.placeholders.map { $0.defaultValue.isEmpty ? $0.name : "\($0.name)=\($0.defaultValue)" }
                        .joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            }
            Toggle("Run immediately (press Return)", isOn: $snippet.runImmediately)
            Picker("Only in folder", selection: $snippet.folderID) {
                Text("Any").tag(UUID?.none)
                ForEach(store.displayOrderedFolders) { Text(store.folderPath($0.id)).tag(UUID?.some($0.id)) }
            }
            Picker("Only for host", selection: $snippet.hostID) {
                Text("Any").tag(UUID?.none)
                ForEach(hostStore.hosts) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            TextField("Notes", text: $snippet.notes, axis: .vertical).lineLimit(1...4)
        }
        .formStyle(.grouped)
    }
}
