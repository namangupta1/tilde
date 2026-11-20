import AppKit
import SwiftUI

// MARK: - Sidebar

struct HostsSection: View {
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var hostStore: HostStore
    @Binding var editing: Host?
    @AppStorage("hostsExpanded") private var expanded = true
    @State private var hovering = false

    var body: some View {
        Section(isExpanded: $expanded) {
            if hostStore.hosts.isEmpty {
                Text("Add a VM or server to query it without logging in every time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            ForEach(hostStore.hosts) { host in
                HostRow(host: host, editing: $editing).tag(host.id)
            }
            .onMove { hostStore.move(from: $0, to: $1) }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "server.rack").foregroundStyle(.secondary)
                Text("Hosts")
                Spacer(minLength: 0)
                if hovering || hostStore.hosts.isEmpty {
                    Menu {
                        Button("New Host…") { editing = Host.blank() }
                        Button("Import from ~/.ssh/config") { hostStore.importSSHConfig(); HostMonitor.shared.refreshAll() }
                    } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Add host")
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
    }
}

struct StatusDot: View {
    let status: HostStatus
    var size: CGFloat = 8

    var color: Color {
        if status.sharedConnection { return .green }
        switch status.reach {
        case .online, .viaProxy: return status.needsLogin ? .orange : .mint
        case .offline: return .red
        case .checking, .unknown: return .gray
        }
    }

    var label: String {
        if status.sharedConnection { return "Connected — shared connection active, new sessions are instant" }
        switch status.reach {
        case .online: return status.needsLogin ? "Reachable — log in once in an SSH tab to enable background queries" : "Reachable"
        case .viaProxy: return "Via jump host"
        case .offline: return "Unreachable"
        case .checking: return "Checking…"
        case .unknown: return "Unknown"
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(status.sharedConnection ? 1 : 0.85))
            if status.sharedConnection {
                Circle().stroke(color.opacity(0.35), lineWidth: 3).frame(width: size + 4, height: size + 4)
            }
        }
        .frame(width: size, height: size)
        .help(label)
    }
}

struct HostRow: View {
    let host: Host
    @Binding var editing: Host?
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var monitor: HostMonitor

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(status: monitor.status(host.id), size: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(host.name.isEmpty ? host.address : host.name).lineLimit(1)
                    if host.isProduction { ProdBadge() }
                }
                Text(host.target)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 1).onEnded { store.selectHost(host.id) })
        .simultaneousGesture(TapGesture(count: 2).onEnded { store.openSSHTab(host.id) })
        .contextMenu { HostMenu(host: host, editing: $editing) }
    }
}

struct HostMenu: View {
    let host: Host
    @Binding var editing: Host?
    @EnvironmentObject var store: WorkspaceStore

    var body: some View {
        Button("Open SSH Tab") { store.openSSHTab(host.id) }
        Button("Open Local Shell with Environment") { store.openEnvShell(host.id) }
        Button("Refresh Status") { Task { await HostMonitor.shared.refresh(host.id, forceFacts: true) } }
        Divider()
        Button("Edit…") { editing = host }
        Button("Copy Address") { copy(host.address) }
        Button("Copy SSH Command") { copy(SSH.commandLine(host)) }
        Button("Disconnect Shared Connection") { HostMonitor.shared.disconnect(host.id) }
        Divider()
        Button("Delete Host", role: .destructive) {
            if store.selectedHostID == host.id { store.selectedHostID = nil }
            HostStore.shared.delete(host.id)
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct ProdBadge: View {
    var body: some View {
        Text("PROD")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.red.opacity(0.85)))
            .foregroundStyle(.white)
    }
}

// MARK: - Detail

struct HostDetailView: View {
    let host: Host
    @Binding var editing: Host?
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var monitor: HostMonitor
    @State private var notes = ""

    private var status: HostStatus { monitor.status(host.id) }

    private static let factOrder: [(String, String)] = [
        ("os", "OS"), ("hostname", "Hostname"), ("ip", "IP"), ("kernel", "Kernel"), ("arch", "Arch"),
        ("uptime", "Uptime"), ("load", "Load"), ("cpus", "CPUs"), ("memory", "Memory"), ("disk", "Disk /"), ("users", "Logged in"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                connectionCard
                factsCard
                commandsCard
                if !host.env.isEmpty { envCard }
                notesCard
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { notes = host.notes; Task { await monitor.refresh(host.id, forceFacts: false) } }
        .onChange(of: host.id) { _, _ in notes = host.notes }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 26))
                .foregroundStyle(host.isProduction ? Color.red : Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(host.name.isEmpty ? host.address : host.name).font(.title2.weight(.semibold))
                    if host.isProduction { ProdBadge() }
                }
                HStack(spacing: 6) {
                    Text(SSH.commandLine(host)).font(.callout.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(SSH.commandLine(host))
                    ForEach(host.tags.filter { !["prod", "production"].contains($0.lowercased()) }, id: \.self) { t in
                        Text(t).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
            }
            Spacer()
            Button { store.openSSHTab(host.id) } label: { Label("Open SSH Tab", systemImage: "terminal") }
                .buttonStyle(.borderedProminent)
                .tint(host.isProduction ? .red : .accentColor)
            Menu {
                HostMenu(host: host, editing: $editing)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
        }
    }

    private var connectionCard: some View {
        Card {
            HStack(spacing: 10) {
                StatusDot(status: status, size: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(StatusDot(status: status).label).font(.callout.weight(.medium))
                    Text(connectionHint).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if status.sharedConnection {
                    Button("Disconnect") { monitor.disconnect(host.id) }.controlSize(.small)
                }
                Button {
                    Task { await monitor.refresh(host.id, forceFacts: true) }
                } label: {
                    if status.fetchingFacts { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
            }
            if let err = status.lastError, !status.sharedConnection {
                Text(err).font(.caption.monospaced()).foregroundStyle(.orange).textSelection(.enabled).lineLimit(3)
            }
        }
    }

    private var connectionHint: String {
        if status.sharedConnection { return "Tabs, splits and queries reuse one SSH connection — no new login or handshake." }
        if status.reach == .offline { return "Can't open a TCP connection to the SSH port. Check VPN, firewall or that the machine is running." }
        if status.needsLogin { return "Background queries can't log in non-interactively. Open an SSH tab once; it stays shared for 15 min after the last tab closes." }
        return "Background queries use your SSH keys/agent and share a connection once one is open."
    }

    private var factsCard: some View {
        Card(title: "System", trailing: host.factsUpdated.map { "Updated \(relative($0))" }) {
            if host.cachedFacts.isEmpty {
                Text(status.fetchingFacts ? "Fetching…" : "No data yet. Refresh, or open an SSH tab once to authenticate.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(Self.factOrder, id: \.0) { key, label in
                        if let v = host.cachedFacts[key], !v.isEmpty {
                            GridRow {
                                Text(label).foregroundStyle(.secondary)
                                Text(v).font(.callout.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    private var commandsCard: some View {
        Card(title: "Quick commands", trailing: nil) {
            if host.commands.isEmpty {
                Text("Save commands you run often (Edit → Quick commands).").font(.callout).foregroundStyle(.secondary)
            }
            FlowButtons(commands: host.commands) { monitor.run($0, on: host.id) }
            let runs = monitor.runs[host.id] ?? []
            ForEach(runs) { run in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if run.running { ProgressView().controlSize(.mini) }
                        else {
                            Image(systemName: run.status == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(run.status == 0 ? .green : .red)
                        }
                        Text(run.name).font(.callout.weight(.medium))
                        Text(run.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if !run.running {
                            Text(String(format: "%.1fs", run.duration)).font(.caption).foregroundStyle(.secondary)
                            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(run.output, forType: .string) }
                                label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy output")
                        }
                    }
                    if !run.output.isEmpty {
                        ScrollView(.vertical) {
                            Text(run.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .topLeading).padding(8)
                        }
                        .frame(maxHeight: 220)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: ThemeManager.shared.palette.background)))
                        .foregroundStyle(Color(nsColor: ThemeManager.shared.palette.foreground))
                    }
                }
            }
            if !runs.isEmpty {
                Button("Clear output") { monitor.clearRuns(host.id) }.buttonStyle(.link).font(.caption)
            }
        }
    }

    private var envCard: some View {
        Card(title: "Environment", trailing: "exported in SSH tabs & “local shell with environment”") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(host.env) { kv in
                    GridRow {
                        Text(kv.key).font(.callout.monospaced().weight(.medium))
                        Text(kv.value).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            Button("Open Local Shell with Environment") { store.openEnvShell(host.id) }.controlSize(.small)
        }
    }

    private var notesCard: some View {
        Card(title: "Notes", trailing: nil) {
            TextField("What runs here, who owns it, gotchas…", text: $notes, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...10)
                .onChange(of: notes) { _, n in HostStore.shared.setNotes(host.id, n) }
        }
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

struct Card<Content: View>: View {
    var title: String?
    var trailing: String?
    @ViewBuilder var content: Content

    init(title: String? = nil, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || trailing != nil {
                HStack {
                    if let title { Text(title).font(.headline) }
                    Spacer()
                    if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

struct FlowButtons: View {
    let commands: [QuickCommand]
    let action: (QuickCommand) -> Void

    var body: some View {
        // Simple wrapping layout via LazyVGrid adaptive columns.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(commands) { c in
                Button { action(c) } label: {
                    Label(c.name.isEmpty ? c.command : c.name, systemImage: "play.fill").lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help(c.command)
            }
        }
    }
}

// MARK: - Editor

struct HostEditor: View {
    @State var host: Host
    let isNew: Bool
    let onSave: (Host) -> Void
    let onCancel: () -> Void
    @State private var tagsText = ""
    @State private var portText = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Connection") {
                    TextField("Name", text: $host.name, prompt: Text("e.g. staging-api"))
                    TextField("Address", text: $host.address, prompt: Text("hostname, IP, or ~/.ssh/config alias"))
                    TextField("User", text: $host.user, prompt: Text("optional"))
                    TextField("Port", text: $portText, prompt: Text("22"))
                    HStack {
                        TextField("Identity file", text: $host.identityFile, prompt: Text("optional, e.g. ~/.ssh/id_ed25519"))
                        Button("Choose…") { chooseKey() }
                    }
                    TextField("Jump host", text: $host.jumpHost, prompt: Text("optional, user@bastion"))
                    TextField("Extra ssh options", text: $host.extraArgs, prompt: Text("optional, e.g. -A -o StrictHostKeyChecking=accept-new"))
                        .font(.body.monospaced())
                    TextField("Tags", text: $tagsText, prompt: Text("comma separated — “prod” turns tabs red"))
                }
                Section("Environment variables") {
                    KeyValueEditor(items: $host.env, keyPlaceholder: "NAME", valuePlaceholder: "value")
                }
                Section("Quick commands") {
                    ForEach($host.commands) { $c in
                        HStack {
                            TextField("Name", text: $c.name).frame(width: 140)
                            TextField("Command", text: $c.command).font(.body.monospaced())
                            Button { host.commands.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button { host.commands.append(QuickCommand(name: "", command: "")) } label: { Label("Add command", systemImage: "plus") }
                        .buttonStyle(.borderless)
                }
                Section("Notes") {
                    TextField("Notes", text: $host.notes, axis: .vertical).lineLimit(2...6)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("Tip: after one interactive login, Tilde reuses the SSH connection for 15 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Host" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 560, height: 620)
        .onAppear {
            tagsText = host.tags.joined(separator: ", ")
            portText = host.port.map(String.init) ?? ""
        }
    }

    private func save() {
        var h = host
        h.address = h.address.trimmingCharacters(in: .whitespaces)
        h.name = h.name.trimmingCharacters(in: .whitespaces)
        if h.name.isEmpty { h.name = h.address }
        h.user = h.user.trimmingCharacters(in: .whitespaces)
        h.port = Int(portText.trimmingCharacters(in: .whitespaces))
        h.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        h.env = h.env.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        h.commands = h.commands.filter { !$0.command.trimmingCharacters(in: .whitespaces).isEmpty }
        onSave(h)
    }

    private func chooseKey() {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".ssh"))
        p.showsHiddenFiles = true
        p.canChooseDirectories = false
        if p.runModal() == .OK, let url = p.url {
            let home = NSHomeDirectory()
            host.identityFile = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        }
    }
}

struct KeyValueEditor: View {
    @Binding var items: [KeyValue]
    let keyPlaceholder: String
    let valuePlaceholder: String

    var body: some View {
        ForEach($items) { $kv in
            HStack {
                TextField(keyPlaceholder, text: $kv.key).font(.body.monospaced()).frame(width: 160)
                TextField(valuePlaceholder, text: $kv.value).font(.body.monospaced())
                Button { items.removeAll { $0.id == kv.id } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
        }
        Button { items.append(KeyValue(key: "", value: "")) } label: { Label("Add variable", systemImage: "plus") }
            .buttonStyle(.borderless)
    }
}
