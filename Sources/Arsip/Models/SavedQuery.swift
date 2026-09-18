import Foundation

/// A named query, stored per database.
struct SavedQuery: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var sql: String
    var updatedAt = Date()
}

enum QueryStore {
    private static func key(_ databaseKey: String) -> String { "queries.\(databaseKey)" }

    static func load(_ databaseKey: String) -> [SavedQuery] {
        guard let data = UserDefaults.standard.data(forKey: key(databaseKey)),
              let queries = try? JSONDecoder().decode([SavedQuery].self, from: data)
        else { return [] }
        return queries
    }

    static func save(_ queries: [SavedQuery], for databaseKey: String) {
        guard let data = try? JSONEncoder().encode(queries) else { return }
        UserDefaults.standard.set(data, forKey: key(databaseKey))
    }

    static func forget(_ databaseKey: String) {
        UserDefaults.standard.removeObject(forKey: key(databaseKey))
    }
}
