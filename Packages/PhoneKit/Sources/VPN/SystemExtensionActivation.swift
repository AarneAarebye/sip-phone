import Foundation
import SystemExtensions

/// One `OSSystemExtensionRequest` activation and its latest known outcome.
///
/// The request can report `needsApproval` first and complete much later (when the user approves in
/// System Settings), so this keeps the latest outcome instead of resolving once.
final class SystemExtensionActivation: NSObject, OSSystemExtensionRequestDelegate, @unchecked Sendable {
    /// `noAnswer`: the system has not reported anything within the wait timeout (the request stays pending).
    enum Outcome: Equatable { case activated, needsApproval, rebootRequired, failed(String), noAnswer }

    private let lock = NSLock()
    private var outcome: Outcome?
    private var waiters: [UUID: CheckedContinuation<Outcome, Never>] = [:]

    /// `submit` is replaceable only so tests can drive the delegate without touching the system.
    init(extensionBundleId: String,
         submit: (OSSystemExtensionRequest) -> Void = { OSSystemExtensionManager.shared.submitRequest($0) }) {
        super.init()
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionBundleId, queue: .main)
        request.delegate = self   // weak in the framework: VPNManager keeps this object alive
        submit(request)
    }

    /// The latest outcome, or the first one the system reports within `timeout`. Returns `.noAnswer`
    /// on timeout or when the calling task is cancelled (the request itself stays pending).
    func current(timeout: TimeInterval = 30) async -> Outcome {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                lock.lock()
                if let outcome { lock.unlock(); return cont.resume(returning: outcome) }
                waiters[id] = cont
                lock.unlock()
                if Task.isCancelled { resume(id, with: .noAnswer) }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { self.resume(id, with: .noAnswer) }
            }
        } onCancel: {
            resume(id, with: .noAnswer)
        }
    }

    private func resume(_ id: UUID, with value: Outcome) {
        lock.lock(); let cont = waiters.removeValue(forKey: id); lock.unlock()
        cont?.resume(returning: value)
    }

    /// Every waiter is removed under the lock before it is resumed, so none is resumed twice.
    private func report(_ new: Outcome) {
        lock.lock()
        outcome = new
        let ready = waiters.values; waiters = [:]
        lock.unlock()
        ready.forEach { $0.resume(returning: new) }
    }

    // MARK: OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) { report(.needsApproval) }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        report(Self.outcome(for: result))
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        report(.failed(Self.message(for: error)))
    }

    // MARK: Pure mapping (unit-tested)

    static func outcome(for result: OSSystemExtensionRequest.Result) -> Outcome {
        switch result {
        case .completed: .activated
        case .willCompleteAfterReboot: .rebootRequired
        @unknown default: .failed("unknown activation result \(result.rawValue)")
        }
    }

    static func message(for error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == OSSystemExtensionErrorDomain, let code = OSSystemExtensionError.Code(rawValue: ns.code) else {
            return error.localizedDescription
        }
        switch code {
        case .unsupportedParentBundleLocation: return "move FritzPhone to the Applications folder and relaunch it"
        case .missingEntitlement: return "the app is not signed with the System Extension entitlement"
        case .extensionNotFound: return "network extension missing from the app bundle"
        case .codeSignatureInvalid: return "network extension signature is invalid"
        case .authorizationRequired, .requestCanceled: return "network extension was not approved"
        default: return "system extension error \(ns.code)"
        }
    }
}
