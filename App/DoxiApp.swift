import SwiftData
import SwiftUI

@main
struct DoxiApp: App {
    @State private var services: AppServices
    private let container: ModelContainer
    private let storageError: String?

    init() {
        let schema = Schema(DoxiSchema.models)
        #if DEBUG
        if UITestSupport.isActive {
            _services = State(initialValue: AppServices(settings: AppSettings(defaults: UITestSupport.freshDefaults()),
                                                        fileStore: FileStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))))
            container = try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
            storageError = nil
            return
        }
        #endif
        _services = State(initialValue: AppServices())
        do {
            container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: DoxiApp.storeURL()))
            storageError = nil
        } catch {
            // Keep the app usable (in memory) and tell the user rather than crashing.
            container = try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
            storageError = "Your library could not be opened (\(error.localizedDescription)). Changes will not be saved until this is resolved."
        }
    }

    /// The SwiftData store (it contains recognised document text) lives in its own
    /// directory with `completeUnlessOpen` protection: encrypted while the device is
    /// locked, except for a database file already open at the moment of locking,
    /// which SQLite needs to finish writes safely.
    static func storeURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Store", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("Doxi.store")
    }

    var body: some Scene {
        WindowGroup {
            RootView(storageError: storageError)
                .environment(services)
        }
        .modelContainer(container)
    }
}
