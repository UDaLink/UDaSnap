import Foundation
import UDaSnapCore

/// Single composition root for app-lifetime services.
///
/// Controllers receive the environment through their initializer where practical;
/// `shared` exists only so AppKit callbacks and small helper types do not each
/// create their own global store. Long-lived state is owned here exactly once.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let aiConfig: AIConfigStore
    let aiConsent: AIConsentCoordinator
    let compliance: ComplianceStore

    init() {
        let consent = AIConsentCoordinator()
        self.aiConsent = consent
        self.aiConfig = AIConfigStore()
        self.compliance = ComplianceStore(consent: consent)
    }
}
