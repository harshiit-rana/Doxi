import DoxiCore
import Foundation
import Observation
import SwiftData

/// Shared services injected into the SwiftUI environment. Views talk to these,
/// never to OCR or model providers directly.
@MainActor
@Observable
final class AppServices {
    let settings: AppSettings
    let fileStore: FileStore
    let processor: DocumentProcessor
    let notifications: NotificationScheduler
    let lock: AppLock
    var importer: DocumentImporter { DocumentImporter(fileStore: fileStore) }
    var obligations: ObligationService { ObligationService(settings: settings) }
    /// A message to show after background work (share imports, failures).
    var banner: String?

    init(settings: AppSettings = AppSettings(), fileStore: FileStore = FileStore()) {
        self.settings = settings
        self.fileStore = fileStore
        self.processor = DocumentProcessor(fileStore: fileStore, settings: settings)
        self.notifications = NotificationScheduler()
        self.lock = AppLock()
    }

    func profile(in context: ModelContext) -> IdentityProfile? {
        let p = try? context.fetch(FetchDescriptor<UserProfileRecord>()).first
        return p.map(\.identity).flatMap { $0.isComplete ? $0 : nil }
    }

    func process(_ doc: DocumentRecord, context: ModelContext) {
        let profile = profile(in: context)
        Task { await processor.process(doc, context: context, profile: profile) }
    }

    func runCloudExtraction(_ doc: DocumentRecord, context: ModelContext) {
        let profile = profile(in: context)
        Task { await processor.runCloudExtraction(doc, context: context, profile: profile) }
    }

    /// Confirms a document: creates obligations and schedules reminders.
    func finalize(_ doc: DocumentRecord, context: ModelContext) {
        obligations.finalize(doc, context: context)
        Task {
            if doc.obligations.contains(where: { $0.dueDate != nil }) {
                await notifications.requestAuthorizationIfNeeded()
            }
            await notifications.reschedule(context: context, settings: settings)
        }
    }

    func rescheduleReminders(context: ModelContext) {
        Task { await notifications.reschedule(context: context, settings: settings) }
    }

    /// Work to do whenever the app becomes active.
    func becameActive(context: ModelContext) {
        let result = ShareInbox.importPending(importer: importer, context: context)
        for doc in result.imported { process(doc, context: context) }
        if !result.imported.isEmpty {
            banner = result.imported.count == 1 ? "Imported 1 shared document." : "Imported \(result.imported.count) shared documents."
        }
        if let error = result.errors.first { banner = error }
        // Resume documents interrupted while processing (e.g. the app was closed).
        let stuck = (try? context.fetch(FetchDescriptor<DocumentRecord>()))?.filter { $0.status.isWorking && !processor.inFlight.contains($0.id) } ?? []
        for doc in stuck { process(doc, context: context) }
        rescheduleReminders(context: context)
    }

    func delete(_ doc: DocumentRecord, context: ModelContext) {
        fileStore.delete(doc.storedFilename)
        context.delete(doc)
        try? context.save()
        rescheduleReminders(context: context)
    }
}
