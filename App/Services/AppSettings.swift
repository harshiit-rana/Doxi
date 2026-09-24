import Foundation
import Observation

/// User preferences stored in UserDefaults. Secrets (API keys) live in the Keychain.
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    /// Use Apple's on-device language model when the device supports it.
    var useOnDeviceModel: Bool { didSet { defaults.set(useOnDeviceModel, forKey: "useOnDeviceModel") } }
    /// Allow cloud AI extraction (document text is sent to the provider).
    var cloudExtractionEnabled: Bool { didSet { defaults.set(cloudExtractionEnabled, forKey: "cloudExtractionEnabled") } }
    /// Run cloud extraction automatically for new documents. Off by default: the
    /// user sends each document explicitly.
    var cloudForNewDocuments: Bool { didSet { defaults.set(cloudForNewDocuments, forKey: "cloudForNewDocuments") } }
    var cloudModel: String { didSet { defaults.set(cloudModel, forKey: "cloudModel") } }
    /// Default reminder offsets in days before the due date.
    var reminderOffsets: [Int] { didSet { defaults.set(reminderOffsets, forKey: "reminderOffsets") } }
    var reminderHour: Int { didSet { defaults.set(reminderHour, forKey: "reminderHour") } }
    var reminderMinute: Int { didSet { defaults.set(reminderMinute, forKey: "reminderMinute") } }
    var appLockEnabled: Bool { didSet { defaults.set(appLockEnabled, forKey: "appLockEnabled") } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }

    static let availableOffsets = [30, 14, 7, 3, 1, 0]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        useOnDeviceModel = defaults.object(forKey: "useOnDeviceModel") as? Bool ?? true
        cloudExtractionEnabled = defaults.bool(forKey: "cloudExtractionEnabled")
        cloudForNewDocuments = defaults.bool(forKey: "cloudForNewDocuments")
        cloudModel = defaults.string(forKey: "cloudModel") ?? "claude-opus-5"
        reminderOffsets = defaults.array(forKey: "reminderOffsets") as? [Int] ?? [30, 14, 7, 0]
        reminderHour = defaults.object(forKey: "reminderHour") as? Int ?? 9
        reminderMinute = defaults.object(forKey: "reminderMinute") as? Int ?? 0
        appLockEnabled = defaults.bool(forKey: "appLockEnabled")
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
    }

    static func offsetLabel(_ days: Int) -> String {
        switch days {
        case 0: return "On the day"
        case 1: return "1 day before"
        default: return "\(days) days before"
        }
    }
}
