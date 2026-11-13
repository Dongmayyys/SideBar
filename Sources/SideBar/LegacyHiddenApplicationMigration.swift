import AppKit

/// Consumes ownership left by versions that hid whole applications. No new
/// ownership is created; only unconfirmed migration failures survive a retry.
enum LegacyHiddenApplicationMigration {
    static let defaultsKey = "SideBarTemporaryHiddenApplicationsV1"

    private struct Application: Codable {
        let pid: Int32
        let bundleID: String
        let launchDate: Date
        let windowIDs: [UInt32]
        let sessionIDs: [String]
        let phase: String
    }

    private struct Archive: Codable {
        let bootSessionID: String
        let applications: [Application]
    }

    static func restore(defaults: Foundation.UserDefaults = .standard,
                        bootSessionID: String = TemporaryStashRecoveryStore.currentBootSessionID(), reason: String) {
        guard let data = defaults.data(forKey: defaultsKey) else { return }
        guard !bootSessionID.isEmpty,
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.bootSessionID == bootSessionID else {
            defaults.removeObject(forKey: defaultsKey)
            defaults.synchronize()
            StashDebugLog.write("legacy app-hide migration reason=\(reason) discarded=invalid-or-old-boot")
            return
        }

        var pending: [Application] = []
        for record in archive.applications {
            guard ["hideRequested", "hiddenOwned", "revealRequested"].contains(record.phase) else { continue }
            let settleUntil = Date().addingTimeInterval(record.phase == "hideRequested" ? 0.8 : 0)
            let deadline = Date().addingTimeInterval(1.2)
            var restored = false
            repeat {
                guard let app = NSRunningApplication(processIdentifier: record.pid), !app.isTerminated,
                      app.bundleIdentifier == record.bundleID, app.processStartDate == record.launchDate else {
                    // Exited/replaced processes cannot inherit the old ownership.
                    restored = true
                    break
                }
                if app.isHidden { _ = app.unhide() }
                if !app.isHidden && Date() >= settleUntil { restored = true; break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            } while Date() < deadline
            if !restored { pending.append(record) }
            StashDebugLog.write("legacy app-hide migration pid=\(record.pid) reason=\(reason) result=\(restored ? "consumed" : "unhide-unconfirmed-retry-next-launch")")
        }

        if pending.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(Archive(bootSessionID: archive.bootSessionID, applications: pending)) {
            defaults.set(data, forKey: defaultsKey)
        }
        defaults.synchronize()
    }
}
