import SwiftData
import SwiftUI

@main
struct DoxiApp: App {
    @State private var services = AppServices()
    private let container: ModelContainer
    private let storageError: String?

    init() {
        let schema = Schema(DoxiSchema.models)
        do {
            container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema))
            storageError = nil
        } catch {
            // Keep the app usable (in memory) and tell the user rather than crashing.
            container = try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
            storageError = "Your library could not be opened (\(error.localizedDescription)). Changes will not be saved until this is resolved."
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(storageError: storageError)
                .environment(services)
        }
        .modelContainer(container)
    }
}
