import Foundation

@main struct InstallerRegression {
    static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("quotabar-install-test-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let source = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/QuotaBar.app", isDirectory: true)
        let destination = root.appendingPathComponent("Applications/QuotaBar.app")
        let backups = root.appendingPathComponent("backups")
        try InstallerFiles.install(source: source, destination: destination, backupDirectory: backups)
        try InstallerFiles.verify(destination)
        let framework = destination.appendingPathComponent("Contents/Frameworks/Sparkle.framework/Versions/Current")
        let link = try files.destinationOfSymbolicLink(atPath: framework.path)
        precondition(link == "B", "Framework symlinks must survive installation")
        let marker = root.appendingPathComponent("account-data")
        try Data("existing account data".utf8).write(to: marker)
        try InstallerFiles.install(source: source, destination: destination, backupDirectory: backups)
        let saved = try files.contentsOfDirectory(atPath: backups.path)
        precondition(saved.count == 1)
        let contents = try String(contentsOf: marker, encoding: .utf8)
        precondition(contents == "existing account data")
        do {
            try InstallerFiles.install(source: root.appendingPathComponent("missing.app"), destination: destination, backupDirectory: backups)
            preconditionFailure("Invalid source accepted")
        } catch { }
        try InstallerFiles.verify(destination)
        print("PASS: fresh install, existing app backup, signed frameworks/symlinks, preserved account files, invalid source leaves installed app intact")
    }
}
