import Foundation

/// A server the user saved. Passwords live in the Keychain, never here.
struct SavedConnection: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = "New Connection"
    var host = "localhost"
    var port = 5432
    var user = NSUserName()
    var database = NSUserName()
    var rememberPassword = true
    var useSSL = false
    var ssh = SSHSettings()

    /// Stable key for the Keychain and saved tabs: survives host/port changes and tunnels.
    func accountKey(database: String) -> String { "\(id.uuidString)/\(database)" }

    var subtitle: String {
        var text = "\(user)@\(host):\(port)"
        if ssh.isEnabled { text += " via \(ssh.host)" }
        return text
    }
}

/// SSH tunnel settings. Authentication uses your keys or ssh-agent, not a typed password.
struct SSHSettings: Codable, Hashable {
    var isEnabled = false
    var host = ""
    var port = 22
    var user = NSUserName()
    /// Optional identity file; empty means ssh picks (agent, ~/.ssh/config, default keys).
    var keyPath = ""
}

@MainActor
enum ConnectionStore {
    private static let key = "savedConnections"

    static func load() -> [SavedConnection] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([SavedConnection].self, from: data)
        else { return [] }
        return saved
    }

    static func save(_ connections: [SavedConnection]) {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// First run: offer the local server, or whatever was last connected to before saving existed.
    static func seed() -> [SavedConnection] {
        let previous = ConnectionConfig.loadLast()
        var connection = SavedConnection()
        connection.name = previous.database
        connection.host = previous.host
        connection.port = previous.port
        connection.user = previous.user
        connection.database = previous.database
        return [connection]
    }
}
