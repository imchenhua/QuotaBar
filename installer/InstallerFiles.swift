import Foundation

enum InstallerFiles {
    static func verify(_ application: URL) throws {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        check.arguments = ["--verify", "--deep", "--strict", application.path]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        try check.run()
        check.waitUntilExit()
        guard check.terminationStatus == 0 else { throw Failure.invalidApplication }
        let infoURL = application.appendingPathComponent("Contents/Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == "dev.rebon.quotabar" else { throw Failure.invalidApplication }
    }

    /// Stage and verify before moving the old app. Account files and the external helper are never touched.
    static func install(source: URL, destination: URL, backupDirectory: URL) throws {
        let files = FileManager.default
        try verify(source)
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".QuotaBar-install-\(UUID().uuidString).app")
        defer { try? files.removeItem(at: stage) }
        try files.copyItem(at: source, to: stage)
        try verify(stage)
        var backup: URL?
        if files.fileExists(atPath: destination.path) {
            try files.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let folder = backupDirectory.appendingPathComponent(UUID().uuidString)
            try files.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let previous = folder.appendingPathComponent("QuotaBar.app")
            try files.moveItem(at: destination, to: previous)
            backup = previous
        }
        do {
            try files.moveItem(at: stage, to: destination)
        } catch {
            if let backup { try? files.moveItem(at: backup, to: destination) }
            throw error
        }
    }

    enum Failure: Error { case invalidApplication }
}
