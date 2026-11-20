import SwiftUI

/// Runs one command on several hosts at once over their shared connections.
struct MultiHostRunView: View {
    @EnvironmentObject var hostStore: HostStore
    let onClose: () -> Void

    struct Result: Identifiable {
        let id: UUID   // host ID
        var name: String
        var running = true
        var status: Int32?
        var output = ""
        var duration: TimeInterval = 0
    }

    @State private var selected = Set<UUID>()
    @State private var command = ""
    @State private var results: [Result] = []
    @State private var expanded = Set<UUID>()
    @FocusState private var commandFocused: Bool

    private var allTags: [String] {
        Array(Set(hostStore.hosts.flatMap(\.tags))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run Command on Hosts").font(.headline)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Hosts").font(.subheadline.weight(.semibold))
                        Spacer()
                        Menu("Select") {
                            Button("All") { selected = Set(hostStore.hosts.map(\.id)) }
                            Button("None") { selected = [] }
                            if !allTags.isEmpty { Divider() }
                            ForEach(allTags, id: \.self) { tag in
                                Button("Tag: \(tag)") { selected = Set(hostStore.hosts.filter { $0.tags.contains(tag) }.map(\.id)) }
                            }
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    List(hostStore.hosts) { h in
                        Toggle(isOn: Binding(get: { selected.contains(h.id) },
                                             set: { if $0 { selected.insert(h.id) } else { selected.remove(h.id) } })) {
                            HStack(spacing: 4) {
                                Text(h.name)
                                if h.isProduction { ProdBadge() }
                            }
                        }
                    }
                    .frame(width: 210)
                    .overlay { if hostStore.hosts.isEmpty { Text("No hosts yet").foregroundStyle(.secondary) } }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Command, e.g. uptime  or  df -h /", text: $command)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .focused($commandFocused)
                            .onSubmit(run)
                        Button(runLabel, action: run)
                            .keyboardShortcut(.defaultAction)
                            .disabled(selected.isEmpty || command.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(results) { r in resultRow(r) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .overlay {
                        if results.isEmpty {
                            Text("Uses each host's shared SSH connection; hosts that need a password are skipped.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 760, height: 480)
        .onAppear { commandFocused = true }
    }

    private var hasProd: Bool { hostStore.hosts.contains { selected.contains($0.id) && $0.isProduction } }
    private var runLabel: String { selected.count <= 1 ? "Run" : "Run on \(selected.count)" }

    @ViewBuilder
    private func resultRow(_ r: Result) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if expanded.contains(r.id) { expanded.remove(r.id) } else { expanded.insert(r.id) }
            } label: {
                HStack(spacing: 6) {
                    if r.running { ProgressView().controlSize(.small) }
                    else { Image(systemName: r.status == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(r.status == 0 ? .green : .red) }
                    Text(r.name).fontWeight(.medium)
                    if !r.running {
                        Text(r.status == 0 ? Notifier.format(r.duration) : "exit \(r.status.map(String.init) ?? "?") · \(Notifier.format(r.duration))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !r.output.isEmpty {
                        Text(r.output.split(separator: "\n").first.map(String.init) ?? "")
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            .opacity(expanded.contains(r.id) ? 0 : 1)
                        Image(systemName: expanded.contains(r.id) ? "chevron.down" : "chevron.right").font(.caption)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded.contains(r.id) && !r.output.isEmpty {
                Text(r.output)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func run() {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty, !selected.isEmpty else { return }
        let hosts = hostStore.hosts.filter { selected.contains($0.id) }
        if hasProd {
            let a = NSAlert()
            a.messageText = "Run on production?"
            a.informativeText = "“\(cmd)” will run on: " + hosts.filter(\.isProduction).map(\.name).joined(separator: ", ")
            a.addButton(withTitle: "Run")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        results = hosts.map { Result(id: $0.id, name: $0.name) }
        expanded = hosts.count == 1 ? [hosts[0].id] : []
        for h in hosts {
            Task {
                let r = await ProcessRunner.run(SSH.executable, SSH.batchArgs(h, command: cmd), timeout: 60)
                guard let i = results.firstIndex(where: { $0.id == h.id }) else { return }
                var out = r.stdout.trimmingCharacters(in: .newlines)
                if !r.stderr.isEmpty { out += (out.isEmpty ? "" : "\n") + r.stderr.trimmingCharacters(in: .newlines) }
                if r.timedOut { out += "\n[timed out after 60s]" }
                results[i].output = out
                results[i].status = r.status
                results[i].duration = r.duration
                results[i].running = false
                if r.status != 0 { expanded.insert(h.id) }
            }
        }
    }
}
