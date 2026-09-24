import Foundation
import SwiftData

/// Files shared into Doxi from other apps (WhatsApp → Share → Doxi) are placed
/// by the Share Extension in the App Group "Inbox" folder; the app imports them
/// when it becomes active.
enum ShareInbox {
    static var groupIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "DoxiAppGroup") as? String ?? "group.com.doxi.app"
    }

    static var inboxURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Imports every waiting file and returns the new records.
    @MainActor
    static func importPending(importer: DocumentImporter, context: ModelContext) -> (imported: [DocumentRecord], errors: [String]) {
        guard let inbox = inboxURL,
              let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.creationDateKey]) else {
            return ([], [])
        }
        var imported: [DocumentRecord] = []
        var errors: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !file.lastPathComponent.hasPrefix(".") {
            do {
                // The extension prefixes names with a timestamp; restore the original name.
                let original = file.lastPathComponent.split(separator: "_", maxSplits: 1).last.map(String.init) ?? file.lastPathComponent
                let named = file.deletingLastPathComponent().appendingPathComponent(original)
                let source = (try? FileManager.default.moveItem(at: file, to: named)) != nil ? named : file
                imported.append(try importer.importFile(at: source, origin: .share, context: context))
                try? FileManager.default.removeItem(at: source)
            } catch {
                errors.append(error.localizedDescription)
                try? FileManager.default.removeItem(at: file)
            }
        }
        return (imported, errors)
    }
}
