import Foundation
import CryptoKit
import Security

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> Data
}

public protocol PinStore: AnyObject, Sendable {
    func load() -> String?
    func save(_ fingerprint: String)
}

public enum PinDecision: Equatable { case acceptAndStore, accept, reject }

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
public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionDelegate, @unchecked Sendable {
    private let username: String, password: String
    private let pins: PinStore
    private var session: URLSession!
    private let lock = NSLock()
    /// Sticky until a later trust evaluation succeeds, so concurrent sends cannot mask a pin rejection.
    private var pinRejected = false

    public init(username: String, password: String, pins: PinStore) {
        self.username = username; self.password = password; self.pins = pins
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    /// Cancels in-flight requests and releases the session (which retains its delegate).
    public func invalidate() { session.invalidateAndCancel() }

    public func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300, 500: return data          // 500 carries a SOAP fault, parsed by SOAP.parseResponse
            case 401: throw FritzError.unauthorized
            default: throw FritzError.http(status)
            }
        } catch let e as URLError where e.code == .cancelled && lock.withLock({ pinRejected }) {
            throw FritzError.certificateChanged
        }
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = space.serverTrust,
                  let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            let fp = CertificatePinning.fingerprint(ofDER: SecCertificateCopyData(leaf) as Data)
            switch CertificatePinning.decide(fingerprint: fp, stored: pins.load()) {
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
            if CertificatePinning.shouldSendCredentials(receivesCredentialSecurely: space.receivesCredentialSecurely,
                                                        previousFailureCount: challenge.previousFailureCount) {
                completionHandler(.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
            } else { completionHandler(.cancelAuthenticationChallenge, nil) }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
