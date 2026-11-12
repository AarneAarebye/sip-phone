import Foundation
import os

/// What happened during one TR-064 HTTP request, for login diagnostics.
///
/// Holds only non-secret facts: never the user name, password, credential, Authorization header, nonces,
/// digests or body content (apart from a SOAP fault's errorCode/errorDescription).
public struct TransportDiagnostics: Sendable, Equatable {
    public enum AuthMethod: String, Sendable, Equatable { case digest = "Digest", basic = "Basic", other }
    public enum ChallengeAnswer: String, Sendable, Equatable { case credentialOffered, refusedInsecure, refusedAfterFailure }

    /// The non-secret parts of a `WWW-Authenticate` header (scheme, realm, algorithm, qop; never the nonce).
    public struct AuthenticateHeader: Sendable, Equatable {
        public var scheme: String
        public var realm: String?
        public var algorithm: String?
        public var qop: String?
        public init(scheme: String, realm: String? = nil, algorithm: String? = nil, qop: String? = nil) {
            self.scheme = scheme; self.realm = realm; self.algorithm = algorithm; self.qop = qop
        }
    }

    public struct Fault: Sendable, Equatable {
        public var code: String
        public var description: String
        public init(code: String, description: String) { self.code = code; self.description = description }
    }

    public enum Event: Sendable, Equatable {
        case serverTrust(decision: PinDecision, fingerprintPrefix: String)
        case authChallenge(method: AuthMethod, realm: String?, algorithm: String?, qop: String?,
                           previousFailureCount: Int, answered: ChallengeAnswer)
        case response(status: Int, authenticate: AuthenticateHeader?, fault: Fault?)
        case urlError(domain: String, code: Int, description: String)
    }

    /// e.g. `POST /upnp/control/x_contact GetPhonebookList` (path only: no host, query or body).
    public var request: String
    public var events: [Event]

    public init(request: String, events: [Event] = []) { self.request = request; self.events = events }

    // MARK: Building (pure, so the sanitization is unit-testable)

    /// Method, URL path and SOAP action name. The query (which may carry a session id) is dropped.
    public static func requestLabel(_ request: URLRequest) -> String {
        let method = request.httpMethod ?? "GET"
        let path = request.url.map { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "" } ?? ""
        var label = "\(method) \(clean(path.isEmpty ? "/" : path, max: 120))"
        if let action = request.value(forHTTPHeaderField: "SOAPAction"),
           let name = action.split(separator: "#").last.map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }),
           action.contains("#"), !name.isEmpty {
            label += " " + clean(name, max: 60)
        }
        return label
    }

    /// Parses the scheme, realm, algorithm and qop of the first challenge in a `WWW-Authenticate` header.
    /// Everything else (nonce, opaque, …) is dropped.
    public static func parseAuthenticate(_ header: String?) -> AuthenticateHeader? {
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty else { return nil }
        let scheme = String(header.prefix { !$0.isWhitespace && $0 != "," })
        guard !scheme.isEmpty, !scheme.contains("=") else { return nil }
        let rest = header.dropFirst(scheme.count)
        var params: [String: String] = [:]
        var i = rest.startIndex
        while i < rest.endIndex {
            // key
            while i < rest.endIndex, rest[i] == " " || rest[i] == "," || rest[i] == "\t" { i = rest.index(after: i) }
            let keyStart = i
            while i < rest.endIndex, rest[i] != "=", rest[i] != ",", !rest[i].isWhitespace { i = rest.index(after: i) }
            let key = rest[keyStart..<i].lowercased()
            while i < rest.endIndex, rest[i].isWhitespace { i = rest.index(after: i) }
            guard i < rest.endIndex, rest[i] == "=" else {
                // A bare token: the start of a second challenge. Only the first one is kept.
                if !key.isEmpty { break }
                continue
            }
            i = rest.index(after: i)
            while i < rest.endIndex, rest[i].isWhitespace { i = rest.index(after: i) }
            var value = ""
            if i < rest.endIndex, rest[i] == "\"" {
                i = rest.index(after: i)
                while i < rest.endIndex, rest[i] != "\"" {
                    if rest[i] == "\\" { i = rest.index(after: i); if i == rest.endIndex { break } }
                    value.append(rest[i]); i = rest.index(after: i)
                }
                if i < rest.endIndex { i = rest.index(after: i) }
            } else {
                while i < rest.endIndex, rest[i] != ",", !rest[i].isWhitespace { value.append(rest[i]); i = rest.index(after: i) }
            }
            if ["realm", "algorithm", "qop"].contains(key), params[key] == nil { params[key] = value }
        }
        return AuthenticateHeader(scheme: clean(scheme, max: 20), realm: params["realm"].map { clean($0, max: 80) },
                                  algorithm: params["algorithm"].map { clean($0, max: 30) },
                                  qop: params["qop"].map { clean($0, max: 30) })
    }

    /// The response event: status, sanitized `WWW-Authenticate`, and a SOAP fault's code/description if the
    /// body is one (the body is otherwise never kept).
    public static func responseEvent(status: Int, headers: [AnyHashable: Any], body: Data?) -> Event {
        var auth: String?
        for (k, v) in headers where (k as? String)?.lowercased() == "www-authenticate" { auth = v as? String }
        var fault: Fault?
        if status >= 400, let body, !body.isEmpty {
            do { _ = try SOAP.parseResponse(body) }
            catch FritzError.fault(let code, let description) {
                fault = Fault(code: clean(code, max: 10), description: clean(description, max: 120))
            } catch {}
        }
        return .response(status: status, authenticate: parseAuthenticate(auth), fault: fault)
    }

    public static func errorEvent(_ error: Error) -> Event {
        let ns = error as NSError
        return .urlError(domain: clean(ns.domain, max: 60), code: ns.code, description: clean(ns.localizedDescription, max: 160))
    }

    public static func authMethod(_ protectionSpaceMethod: String) -> AuthMethod {
        switch protectionSpaceMethod {
        case NSURLAuthenticationMethodHTTPDigest: return .digest
        case NSURLAuthenticationMethodHTTPBasic: return .basic
        default: return .other
        }
    }

    /// Printable, single-line, length-capped.
    static func clean(_ s: String, max: Int) -> String {
        let flat = String(s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }

    // MARK: Rendering

    public static func describe(_ event: Event) -> String {
        switch event {
        case .serverTrust(let decision, let prefix):
            return "TLS server trust: \(decision) (certificate \(prefix.isEmpty ? "unavailable" : prefix + "…"))"
        case .authChallenge(let method, let realm, let algorithm, let qop, let failures, let answered):
            var s = "Auth challenge: \(method.rawValue)"
            if let realm { s += " realm=\"\(realm)\"" }
            if let algorithm { s += " algorithm=\(algorithm)" }
            if let qop { s += " qop=\(qop)" }
            return s + ", previousFailureCount=\(failures) -> \(answered.rawValue)"
        case .response(let status, let auth, let fault):
            var s = "Response: HTTP \(status)"
            if let auth {
                s += ", WWW-Authenticate: \(auth.scheme)"
                if let r = auth.realm { s += " realm=\"\(r)\"" }
                if let a = auth.algorithm { s += " algorithm=\(a)" }
                if let q = auth.qop { s += " qop=\(q)" }
            }
            if let fault { s += ", SOAP fault \(fault.code)\(fault.description.isEmpty ? "" : ": " + fault.description)" }
            return s
        case .urlError(let domain, let code, let description):
            return "Error: \(domain) \(code) \(description)"
        }
    }

    public var lines: [String] { ["Request: \(request)"] + events.map { "  " + Self.describe($0) } }
    public var text: String { lines.joined(separator: "\n") }

    /// A few words for the popover's phone-book notice, e.g. "HTTP 401 after Digest challenge, credentials offered".
    public var shortSummary: String? {
        let challenges = events.compactMap { e -> (AuthMethod, ChallengeAnswer)? in
            if case .authChallenge(let m, _, _, _, _, let a) = e { return (m, a) }; return nil
        }
        let challengeNote: String
        if let last = challenges.last {
            let offered = challenges.contains { $0.1 == .credentialOffered }
            let name = last.0 == .other ? "auth" : last.0.rawValue
            switch last.1 {
            case .credentialOffered: challengeNote = "after \(name) challenge, credentials offered"
            case .refusedAfterFailure: challengeNote = "after \(name) challenge, credentials \(offered ? "offered and rejected" : "refused")"
            case .refusedInsecure: challengeNote = "after \(name) challenge, credentials withheld (insecure)"
            }
        } else {
            challengeNote = "no auth challenge answered"
        }
        if events.contains(where: { if case .serverTrust(.reject, _) = $0 { return true }; return false }) {
            return "certificate pin rejected"
        }
        for e in events.reversed() {
            switch e {
            case .response(let status, _, let fault):
                if let fault { return "HTTP \(status), SOAP fault \(fault.code)" }
                return status == 401 ? "HTTP 401 \(challengeNote)" : "HTTP \(status)"
            case .urlError(let domain, let code, _):
                if !challenges.isEmpty, domain == NSURLErrorDomain, code == NSURLErrorCancelled { return "cancelled \(challengeNote)" }
                return "\(domain == NSURLErrorDomain ? "URL error" : domain) \(code)"
            default: continue
            }
        }
        return nil
    }
}

/// Overall verdict of a TR-064 login test.
public enum TR064Verdict: Equatable, Sendable {
    case ok
    /// The box challenged, we answered with the credentials, and it still refused them.
    case rejected
    /// HTTP 401 but no challenge was answered with credentials: an app-side problem (or no usable challenge).
    case credentialsNotSent
    /// SOAP fault 606: the user exists but lacks the right for this action.
    case lacksRights
    case fault(code: String, description: String)
    case tlsOrPin
    case unreachable
    case tr064Disabled
    case http(Int)
    case notConfigured
    case unknown

    public var summary: String {
        switch self {
        case .ok: return "OK – login accepted"
        case .rejected: return "REJECTED – the FRITZ!Box refused the user name or password that was sent"
        case .credentialsNotSent:
            return "REJECTED WITHOUT CREDENTIALS – HTTP 401, but no challenge was answered with credentials (app-side problem)"
        case .lacksRights: return "LACKS RIGHTS – login works, but the user may not access this (SOAP fault 606)"
        case .fault(let code, let d): return "REFUSED – SOAP fault \(code)\(d.isEmpty ? "" : ": " + d)"
        case .tlsOrPin: return "TLS OR PIN PROBLEM – the HTTPS connection or certificate pin failed"
        case .unreachable: return "UNREACHABLE – the FRITZ!Box did not answer"
        case .tr064Disabled: return "TR-064 DISABLED? – connection refused or no TR-064 service (check \"Allow access for applications\")"
        case .http(let code): return "HTTP ERROR \(code)"
        case .notConfigured: return "NOT CONFIGURED – TR-064 user or password missing in Settings"
        case .unknown: return "UNKNOWN – no conclusive result"
        }
    }
}

public enum TR064Diagnosis {
    /// Pure verdict from what the transport recorded plus the error (if any) the call threw.
    public static func verdict(diagnostics d: TransportDiagnostics?, error: Error?) -> TR064Verdict {
        if let fe = error as? FritzError, fe == .notConfigured { return .notConfigured }
        if (error as? FritzError) == .certificateChanged { return .tlsOrPin }
        let events = d?.events ?? []
        if events.contains(where: { if case .serverTrust(.reject, _) = $0 { return true }; return false }) { return .tlsOrPin }
        let answers = events.compactMap { e -> TransportDiagnostics.ChallengeAnswer? in
            if case .authChallenge(_, _, _, _, _, let a) = e { return a }; return nil
        }
        let offered = answers.contains(.credentialOffered)
        let last = events.last { if case .serverTrust = $0 { return false }; return true }

        switch last {
        case .response(let status, _, let fault)?:
            if let fault { return fault.code == "606" ? .lacksRights : .fault(code: fault.code, description: fault.description) }
            switch status {
            case 200..<300: return error == nil ? .ok : .unknown
            case 401: return offered ? .rejected : .credentialsNotSent
            case 404: return .tr064Disabled
            default: return .http(status)
            }
        case .urlError(let domain, let code, _)?:
            guard domain == NSURLErrorDomain else { return .unknown }
            switch code {
            case NSURLErrorCancelled:
                if answers.contains(.refusedAfterFailure) { return offered ? .rejected : .credentialsNotSent }
                if answers.contains(.refusedInsecure) { return .credentialsNotSent }
                return .unknown
            case NSURLErrorCannotConnectToHost: return .tr064Disabled
            case NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorInternationalRoamingOff,
                 NSURLErrorDataNotAllowed:
                return .unreachable
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired:
                return .tlsOrPin
            default: return .unknown
            }
        default:
            if let fe = error as? FritzError, case .fault(let code, let desc) = fe {
                return code == "606" ? .lacksRights : .fault(code: code, description: desc)
            }
            return error == nil && d != nil ? .ok : .unknown
        }
    }
}

/// Result of `FritzTR064Client.checkLogin()`: sanitized, safe to show and copy.
public struct TR064LoginCheck: Sendable, Equatable {
    public var verdict: TR064Verdict
    public var diagnostics: TransportDiagnostics?
    public var errorDescription: String?
    public var model: String?
    public var firmware: String?

    public init(verdict: TR064Verdict, diagnostics: TransportDiagnostics?, errorDescription: String?,
                model: String? = nil, firmware: String? = nil) {
        self.verdict = verdict; self.diagnostics = diagnostics; self.errorDescription = errorDescription
        self.model = model; self.firmware = firmware
    }

    public var text: String {
        var lines = ["TR-064 login test: \(verdict.summary)"]
        if model != nil || firmware != nil {
            lines.append("Device: \(model ?? "unknown model")\(firmware.map { ", FRITZ!OS \($0)" } ?? "")")
        }
        if let diagnostics { lines += diagnostics.lines } else { lines.append("No request was made.") }
        if let errorDescription { lines.append("Result: \(errorDescription)") }
        return lines.joined(separator: "\n")
    }
}

enum TR064Log {
    static let logger = Logger(subsystem: "com.aarneaarebye.sipphone", category: "tr064")

    /// Every field logged here is from the sanitized diagnostics (no user name, password, header or nonce).
    static func log(_ d: TransportDiagnostics) {
        for event in d.events {
            let line = TransportDiagnostics.describe(event)
            logger.info("\(d.request, privacy: .public): \(line, privacy: .public)")
        }
    }
}
