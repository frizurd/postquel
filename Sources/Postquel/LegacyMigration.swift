import Foundation

/// Postquel used to be called Arsip, with its own bundle identifier, so its settings (saved
/// connections, queries, open tabs) and Keychain passwords live under the old names. This brings
/// them over once, so renaming doesn't lose anything.
enum LegacyMigration {
    static let bundleIdentifier = "dev.arsip.Arsip"
    static let keychainService = "dev.arsip.connection"
    private static let doneKey = "migratedFromArsip"

    /// Copies the old app's settings into Postquel's, without overwriting anything already set.
    /// Call before any view reads its settings.
    static func migrateSettings() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        if let old = defaults.persistentDomain(forName: bundleIdentifier) {
            // Window frames are keyed by the old module name and would never be read again.
            for (key, value) in old where defaults.object(forKey: key) == nil
                && !key.hasPrefix("NSWindow Frame") && !key.hasPrefix("NSSplitView") {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: doneKey)
        // The old app's scratch folder only held temporary assistant files.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: support.appendingPathComponent("Arsip/Assistant", isDirectory: true))
        try? FileManager.default.removeItem(at: support.appendingPathComponent("Arsip", isDirectory: true))
    }
}
