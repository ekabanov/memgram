import Foundation
import Security

/// Runtime checks for code-signing entitlements.
///
/// Contributors building without a paid Apple Developer account strip the
/// iCloud/push entitlements from project.yml (see README) — the app must
/// degrade gracefully instead of crashing at `CKContainer` init.
enum Entitlements {

    /// True when the running binary carries the given entitlement.
    static func has(_ name: String) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, name as CFString, nil) != nil
        #else
        // SecTask is macOS-only. iOS builds are distributed with the entitlement
        // baked in (App Store / TestFlight), so assume present.
        return true
        #endif
    }

    /// True when the binary is signed with the CloudKit entitlement.
    /// Without it, any `CKContainer` access crashes the process.
    static var hasCloudKit: Bool {
        has("com.apple.developer.icloud-services")
    }
}
