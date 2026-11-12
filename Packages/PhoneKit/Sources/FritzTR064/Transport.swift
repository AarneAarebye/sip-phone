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
}

/// URLSession-backed transport: HTTP digest auth via challenge handling, trust-on-first-use certificate pinning.
public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionDelegate, @unchecked Sendable {
    private let username: String, password: String
    private let pins: PinStore
    private var session: URLSession!
    private let lock = NSLock()
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
        lock.withLock { pinRejected = false }
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
            let fp = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
            switch CertificatePinning.decide(fingerprint: fp, stored: pins.load()) {
            case .acceptAndStore: pins.save(fp); completionHandler(.useCredential, URLCredential(trust: trust))
            case .accept: completionHandler(.useCredential, URLCredential(trust: trust))
            case .reject:
                lock.withLock { pinRejected = true }
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        case NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodHTTPBasic:
            if challenge.previousFailureCount > 0 { completionHandler(.cancelAuthenticationChallenge, nil) }
            else { completionHandler(.useCredential, URLCredential(user: username, password: password, persistence: .forSession)) }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
