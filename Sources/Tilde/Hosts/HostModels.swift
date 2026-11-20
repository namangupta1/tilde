import Foundation

struct KeyValue: Codable, Hashable, Identifiable {
    var id = UUID()
    var key: String
    var value: String
}

struct QuickCommand: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var command: String
}

/// A saved remote machine (VM, server, container host…).
struct Host: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// Hostname, IP, or an alias from ~/.ssh/config.
    var address: String
    var user: String = ""
    var port: Int?
    var identityFile: String = ""
    var jumpHost: String = ""
    /// Extra ssh arguments, e.g. `-o StrictHostKeyChecking=accept-new -A`.
    var extraArgs: String = ""
    var tags: [String] = []
    var notes: String = ""
    var env: [KeyValue] = []
    var commands: [QuickCommand] = []
    /// Last facts fetched, kept so the panel shows something instantly on launch.
    var cachedFacts: [String: String] = [:]
    var factsUpdated: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, address, user, port, identityFile, jumpHost, extraArgs, tags, notes, env, commands, cachedFacts, factsUpdated
    }

    init(name: String, address: String, commands: [QuickCommand] = []) {
        self.name = name
        self.address = address
        self.commands = commands
    }

    /// Tolerant decoding so new fields never break older saved files.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile) ?? ""
        jumpHost = try c.decodeIfPresent(String.self, forKey: .jumpHost) ?? ""
        extraArgs = try c.decodeIfPresent(String.self, forKey: .extraArgs) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        env = try c.decodeIfPresent([KeyValue].self, forKey: .env) ?? []
        commands = try c.decodeIfPresent([QuickCommand].self, forKey: .commands) ?? []
        cachedFacts = try c.decodeIfPresent([String: String].self, forKey: .cachedFacts) ?? [:]
        factsUpdated = try c.decodeIfPresent(Date.self, forKey: .factsUpdated)
    }

    var isProduction: Bool {
        tags.contains { let t = $0.lowercased(); return t == "prod" || t == "production" || t.hasPrefix("prod-") }
    }

    /// user@address for display.
    var target: String { user.isEmpty ? address : "\(user)@\(address)" }

    static func blank() -> Host {
        Host(name: "", address: "", commands: [
            QuickCommand(name: "Disk usage", command: "df -h"),
            QuickCommand(name: "Top processes", command: "ps aux --sort=-%cpu 2>/dev/null | head -15 || ps aux | head -15"),
        ])
    }
}

/// What a pane is connected to. nil = plain local shell.
enum PaneConnection: Codable, Hashable {
    case ssh(hostID: UUID)
    case localEnv(hostID: UUID)

    var hostID: UUID {
        switch self {
        case .ssh(let id), .localEnv(let id): return id
        }
    }
}
