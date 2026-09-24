import Foundation
import LocalAuthentication
import Observation

/// Optional Face ID / passcode lock shown when the app returns to the foreground.
@MainActor
@Observable
final class AppLock {
    private(set) var isLocked = false
    private(set) var lastError: String?

    func lock(ifEnabled enabled: Bool) {
        if enabled { isLocked = true }
    }

    func unlock() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode set on the device: the lock cannot be enforced.
            lastError = error?.localizedDescription
            isLocked = false
            return
        }
        do {
            if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your documents") {
                isLocked = false
                lastError = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Passcode"
        }
    }
}
