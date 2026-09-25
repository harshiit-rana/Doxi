import DoxiCore
import Foundation
import Observation
import SwiftData
import UserNotifications

/// Schedules local reminders for open obligations. iOS allows 64 pending
/// notifications per app, so `ReminderPlanner` picks the nearest ones and this
/// scheduler re-plans on launch, on foreground and whenever obligations change.
@MainActor
@Observable
final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var scheduledCount = 0
    /// Set when the user taps a reminder; the UI opens this document.
    var openDocumentRequest: UUID?

    override init() {
        super.init()
        center.delegate = self
    }

    var isDenied: Bool { authorization == .denied }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Asks for permission the first time reminders are actually needed.
    func requestAuthorizationIfNeeded() async {
        await refreshAuthorization()
        guard authorization == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorization()
    }

    func reschedule(context: ModelContext, settings: AppSettings) async {
        await refreshAuthorization()
        let obligations = (try? context.fetch(FetchDescriptor<ObligationRecord>())) ?? []
        let candidates = NotificationScheduler.candidates(from: obligations, today: .today())
        let planner = ReminderPlanner(hour: settings.reminderHour, minute: settings.reminderMinute)
        let plan = planner.plan(candidates, now: .now)
        let planned = Set(plan.map(\.identifier))

        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("doxi.") }
        let stale = pending.filter { !planned.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        guard authorization == .authorized || authorization == .provisional || authorization == .ephemeral else {
            scheduledCount = 0
            return
        }
        let existing = Set(pending)
        let docIDs = Dictionary(obligations.compactMap { ob in ob.document.map { (ob.id, $0.id) } }, uniquingKeysWith: { a, _ in a })
        for item in plan where !existing.contains(item.identifier) {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            content.threadIdentifier = docIDs[item.obligationID]?.uuidString ?? "doxi"
            content.userInfo = ["obligationID": item.obligationID.uuidString, "documentID": docIDs[item.obligationID]?.uuidString ?? ""]
            var components = CalendarDate.gregorian().dateComponents([.year, .month, .day, .hour, .minute], from: item.fireDate)
            components.second = 0
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: item.identifier, content: content, trigger: trigger))
        }
        scheduledCount = plan.count
    }

    /// Obligations that should have reminders: from documents the user confirmed,
    /// still open, with a due date and reminders switched on.
    static func candidates(from obligations: [ObligationRecord], today: CalendarDate) -> [ReminderCandidate] {
        obligations.compactMap { ob in
            guard ob.remindersEnabled, let due = ob.dueDate, let doc = ob.document, doc.confirmedAt != nil,
                  ob.status(today: today).isOpen else { return nil }
            return ReminderCandidate(obligationID: ob.id, title: ob.title, body: ob.counterparty ?? doc.title, dueDate: due,
                                     recurrence: ob.recurrence, offsets: ob.reminderOffsets, isOpen: true)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let idString = info["documentID"] as? String, let id = UUID(uuidString: idString) else { return }
        await MainActor.run { self.openDocumentRequest = id }
    }
}
