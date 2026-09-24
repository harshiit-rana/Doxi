import Foundation

/// Stores document files inside the app container with complete file
/// protection: files are encrypted and unreadable while the device is locked.
struct FileStore: Sendable {
    let documentsDirectory: URL

    init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        documentsDirectory = base.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.complete])
    }

    func url(for storedFilename: String) -> URL {
        documentsDirectory.appendingPathComponent(storedFilename)
    }

    /// Writes data under a new unique name and returns that name.
    func write(_ data: Data, fileExtension: String = "pdf") throws -> String {
        let name = UUID().uuidString + "." + fileExtension
        try data.write(to: url(for: name), options: [.atomic, .completeFileProtection])
        return name
    }

    func overwrite(_ data: Data, storedFilename: String) throws {
        try data.write(to: url(for: storedFilename), options: [.atomic, .completeFileProtection])
    }

    func delete(_ storedFilename: String) {
        try? FileManager.default.removeItem(at: url(for: storedFilename))
    }
}
