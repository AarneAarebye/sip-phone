import Foundation
import CryptoKit
import Security

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> Data
    /// Sanitized record of the most recent request (nil when the transport does not record any).
    var lastDiagnostics: TransportDiagnostics? { get }
}

public extension HTTPTransport {
    var lastDiagnostics: TransportDiagnostics? { nil }
}

public protocol PinStore: AnyObject, Sendable {
    func load() -> String?
    func save(_ fingerprint: String)
}

public enum PinDecision: Equatable, Sendable { case acceptAndStore, accept, reject }

public enum CertificatePinning {
    public static func decide(fingerprint: String, stored: String?) -> PinDecision {
        guard let stored else { return .acceptAndStore }
        return stored == fingerprint ? .accept : .reject
    }

    /// Lower-case hex SHA-256 of a DER certificate: the stored pin format.
    public static func fingerprint(ofDER der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Reachability probe verdict: the listener counts as OUR FRITZ!Box only if its leaf certificate
    /// matches the stored pin (a different box on a visited network must not stop the VPN from starting).
    public static func probeMatchesPin(leafDER: Data?, pinned: String) -> Bool {
        guard let leafDER, !pinned.isEmpty else { return false }
        return fingerprint(ofDER: leafDER) == pinned.lowercased()
    }

    /// HTTP credentials are only handed out over a protection space that receives them securely (https),
    /// and only once per challenge.
    public static func shouldSendCredentials(receivesCredentialSecurely: Bool, previousFailureCount: Int) -> Bool {
        receivesCredentialSecurely && previousFailureCount == 0
    }
}

/// URLSession-backed transport: HTTP digest auth via challenge handling, trust-on-first-use certificate pinning.
///
/// Every challenge (server trust as well as Digest/Basic) is answered in the task-level delegate method:
/// URLSession delivers per-task challenges such as HTTP Digest only there (a session-level-only delegate
/// leaves them to default handling, i.e. no credentials are sent). Each request also records sanitized
/// `TransportDiagnostics` (see `lastDiagnostics`), which are logged under subsystem com.aarneaarebye.sipphone,
/// category tr064.
public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let username: String, password: String
    private let pins: PinStore
    private var session: URLSession!
    private let lock = NSLock()
    /// Sticky until a later trust evaluation succeeds, so concurrent sends cannot mask a pin rejection.
    private var pinRejected = false
    /// Events of in-flight tasks, by task identifier.
    private var inFlight: [Int: [TransportDiagnostics.Event]] = [:]
    private var last: TransportDiagnostics?

    public convenience init(username: String, password: String, pins: PinStore) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        self.init(username: username, password: password, pins: pins, configuration: cfg)
    }

    /// `configuration` is injectable for tests (a stub URLProtocol); the app uses the convenience init.
    init(username: String, password: String, pins: PinStore, configuration: URLSessionConfiguration) {
        self.username = username; self.password = password; self.pins = pins
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Cancels in-flight requests and releases the session (which retains its delegate).
    public func invalidate() { session.invalidateAndCancel() }

    /// Sanitized record of the most recently finished request.
    public var lastDiagnostics: TransportDiagnostics? { lock.withLock { last } }

    private func record(_ event: TransportDiagnostics.Event, task: URLSessionTask) {
        lock.withLock { inFlight[task.taskIdentifier, default: []].append(event) }
    }

    private func takeEvents(_ id: Int?) -> [TransportDiagnostics.Event] {
        guard let id else { return [] }
        return lock.withLock { inFlight.removeValue(forKey: id) } ?? []
    }

    public func send(_ request: URLRequest) async throws -> Data {
        let label = TransportDiagnostics.requestLabel(request)
        let handle = TaskHandle()
        let (data, response, error, diagnostics): (Data?, URLResponse?, Error?, TransportDiagnostics) =
            await withTaskCancellationHandler {
                await withCheckedContinuation { cont in
                    let task = session.dataTask(with: request) { [weak self] data, response, error in
                        var events = self?.takeEvents(handle.identifier) ?? []
                        if let http = response as? HTTPURLResponse {
                            events.append(TransportDiagnostics.responseEvent(status: http.statusCode,
                                                                            headers: http.allHeaderFields, body: data))
                        }
                        if let error { events.append(TransportDiagnostics.errorEvent(error)) }
                        cont.resume(returning: (data, response, error, TransportDiagnostics(request: label, events: events)))
                    }
                    lock.withLock { inFlight[task.taskIdentifier] = [] }
                    handle.set(task)
                    task.resume()
                }
            } onCancel: { handle.cancel() }

        lock.withLock { last = diagnostics }
        TR064Log.log(diagnostics)

        if let error {
            if let e = error as? URLError, e.code == .cancelled {
                if lock.withLock({ pinRejected }) { throw FritzError.certificateChanged }
                // Credentials were offered and the box challenged again: report it as a rejected login.
                if diagnostics.events.contains(where: {
                    if case .authChallenge(_, _, _, _, _, .refusedAfterFailure) = $0 { return true }; return false
                }) { throw FritzError.unauthorized }
            }
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300, 500: return data ?? Data()     // 500 carries a SOAP fault, parsed by SOAP.parseResponse
        case 401: throw FritzError.unauthorized
        default: throw FritzError.http(status)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = space.serverTrust,
                  let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
                record(.serverTrust(decision: .reject, fingerprintPrefix: ""), task: task)
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            let fp = CertificatePinning.fingerprint(ofDER: SecCertificateCopyData(leaf) as Data)
            let decision = CertificatePinning.decide(fingerprint: fp, stored: pins.load())
            record(.serverTrust(decision: decision, fingerprintPrefix: String(fp.prefix(8))), task: task)
            switch decision {
            case .acceptAndStore:
                pins.save(fp); lock.withLock { pinRejected = false }
                completionHandler(.useCredential, URLCredential(trust: trust))
            case .accept:
                lock.withLock { pinRejected = false }
                completionHandler(.useCredential, URLCredential(trust: trust))
            case .reject:
                lock.withLock { pinRejected = true }
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        case NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodHTTPBasic:
            let header = (challenge.failureResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate")
            let parsed = TransportDiagnostics.parseAuthenticate(header)
            let send = CertificatePinning.shouldSendCredentials(receivesCredentialSecurely: space.receivesCredentialSecurely,
                                                                previousFailureCount: challenge.previousFailureCount)
            let answer: TransportDiagnostics.ChallengeAnswer =
                send ? .credentialOffered : (space.receivesCredentialSecurely ? .refusedAfterFailure : .refusedInsecure)
            record(.authChallenge(method: TransportDiagnostics.authMethod(space.authenticationMethod),
                                  realm: space.realm.map { TransportDiagnostics.clean($0, max: 80) },
                                  algorithm: parsed?.algorithm, qop: parsed?.qop,
                                  previousFailureCount: challenge.previousFailureCount, answered: answer), task: task)
            if send {
                completionHandler(.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
            } else { completionHandler(.cancelAuthenticationChallenge, nil) }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// Lets the async cancellation handler reach a task created inside the continuation.
private final class TaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    var identifier: Int? { lock.withLock { task?.taskIdentifier } }
    func set(_ t: URLSessionTask) {
        let c = lock.withLock { task = t; return cancelled }
        if c { t.cancel() }
    }
    func cancel() {
        let t = lock.withLock { cancelled = true; return task }
        t?.cancel()
    }
}
