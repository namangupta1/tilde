import AppKit
import Foundation

/// Saved hosts, persisted to Application Support/Tilde/hosts.json.
@MainActor
final class HostStore: ObservableObject {
    static let shared = HostStore()

    @Published var hosts: [Host] = [] { didSet { scheduleSave() } }
    private var saveWork: DispatchWorkItem?

    static let fileURL: URL = WorkspaceStore.fileURL.deletingLastPathComponent().appendingPathComponent("hosts.json")

    init() {
        if let data = try? Data(contentsOf: Self.fileURL) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            hosts = (try? dec.decode([Host].self, from: data)) ?? []
        }
    }

    func host(_ id: UUID) -> Host? { hosts.first { $0.id == id } }

    func upsert(_ h: Host) {
        if let i = hosts.firstIndex(where: { $0.id == h.id }) {
            let old = hosts[i]
            var n = h
            // Keep cache fields owned by the monitor.
            n.cachedFacts = old.cachedFacts
            n.factsUpdated = old.factsUpdated
            hosts[i] = n
        } else {
            hosts.append(h)
        }
        HostMonitor.shared.invalidate(h.id)
    }

    func delete(_ id: UUID) {
        hosts.removeAll { $0.id == id }
    }

    func setNotes(_ id: UUID, _ notes: String) {
        guard let i = hosts.firstIndex(where: { $0.id == id }), hosts[i].notes != notes else { return }
        hosts[i].notes = notes
    }

    func storeFacts(_ id: UUID, _ facts: [String: String]) {
        guard let i = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[i].cachedFacts = facts
        hosts[i].factsUpdated = Date()
    }

    func move(from: IndexSet, to: Int) { hosts.move(fromOffsets: from, toOffset: to) }

    // MARK: ~/.ssh/config import

    /// Adds every concrete `Host` entry (no wildcards) from ~/.ssh/config that isn't already saved.
    /// The alias is used as the address so all of the user's ssh options keep applying.
    @discardableResult
    func importSSHConfig() -> Int {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        var added = 0
        var current: [String] = []
        var fields: [String: String] = [:]

        func flush() {
            for alias in current where !alias.contains("*") && !alias.contains("?") && !alias.hasPrefix("!") {
                guard !hosts.contains(where: { $0.address == alias }) else { continue }
                var h = Host.blank()
                h.name = alias
                h.address = alias
                h.notes = [fields["hostname"].map { "HostName \($0)" }, fields["user"].map { "User \($0)" }]
                    .compactMap { $0 }.joined(separator: " · ")
                hosts.append(h)
                added += 1
            }
            current = []
            fields = [:]
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=\""))
            if key == "host" {
                flush()
                current = value.split(separator: " ").map(String.init)
            } else if key == "match" {
                flush()
            } else if !current.isEmpty {
                fields[key] = value
            }
        }
        flush()
        return added
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func saveNow() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(hosts) { try? data.write(to: Self.fileURL, options: .atomic) }
    }
}
