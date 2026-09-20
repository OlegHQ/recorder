import Foundation
import UniformTypeIdentifiers

enum AppIdentity {
    static let bundleID = "space.microapps.recorder"
    static let legacyBundleID = "sh.nexo.recorder"
    static let projectTypes = [UTType(exportedAs: "space.microapps.recorder.project"),
                               UTType(importedAs: "sh.nexo.recorder.project")]

    /// Copy preferences once, before any settings singleton reads them. Preserve
    /// both the old domain and any choices already saved under the new identity.
    static func migratePreferences(defaults: UserDefaults = .standard,
                                   from oldDomain: String = legacyBundleID,
                                   to newDomain: String = bundleID) {
        let marker = "migration.microappsIdentity.v1"
        var current = defaults.persistentDomain(forName: newDomain) ?? [:]
        guard current[marker] as? Bool != true else { return }
        let legacy = defaults.persistentDomain(forName: oldDomain) ?? [:]
        current = legacy.merging(current) { _, new in new }
        current[marker] = true
        defaults.setPersistentDomain(current, forName: newDomain)
    }
}
