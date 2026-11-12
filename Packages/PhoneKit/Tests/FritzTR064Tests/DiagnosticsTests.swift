// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import XCTest
import PhoneCore
@testable import FritzTR064

private typealias D = TransportDiagnostics

private let secretUser = "alice-tr064"
private let secretPassword = "S3cr3t-Pa55w0rd"
private let secretNonce = "NONCE0123456789abcdef"
private let secretDigest = "6629fae49393a05397450978507c4ef1"

private func faultBody(_ code: String, _ desc: String, extra: String = "") -> Data {
    Data("""
    <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault>\
    <faultstring>UPnPError</faultstring><detail><UPnPError><errorCode>\(code)</errorCode>\
    <errorDescription>\(desc)</errorDescription></UPnPError>\(extra)</detail></s:Fault></s:Body></s:Envelope>
    """.utf8)
}

private let digestHeader = "Digest realm=\"HTTPS Access\",nonce=\"\(secretNonce)\",algorithm=MD5,qop=\"auth\",opaque=\"OPAQUE42\""

final class VerdictTests: XCTestCase {
    private func diag(_ events: D.Event...) -> D { D(request: "POST /upnp/control/x_contact GetPhonebookList", events: events) }
    private let offered = D.Event.authChallenge(method: .digest, realm: "HTTPS Access", algorithm: "MD5", qop: "auth",
                                                previousFailureCount: 0, answered: .credentialOffered)
    private let trust = D.Event.serverTrust(decision: .accept, fingerprintPrefix: "1a2b3c4d")

    func testOK() {
        XCTAssertEqual(TR064Diagnosis.verdict(diagnostics: diag(trust, offered, .response(status: 200, authenticate: nil, fault: nil)),
                                              error: nil), .ok)
    }

    func testUnauthorizedAfterCredentialsOffered() {
        let d = diag(trust, offered, .response(status: 401, authenticate: D.parseAuthenticate(digestHeader), fault: nil))
        XCTAssertEqual(TR064Diagnosis.verdict(diagnostics: d, error: FritzError.unauthorized), .rejected)
        XCTAssertEqual(d.shortSummary, "HTTP 401 after Digest challenge, credentials offered")
    }

    func testRejectedAfterRetryChallengeCancels() {
        let again = D.Event.authChallenge(method: .digest, realm: "HTTPS Access", algorithm: nil, qop: nil,
                                          previousFailureCount: 1, answered: .refusedAfterFailure)
        let d = diag(trust, offered, again, .urlError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, description: "cancelled"))
        XCTAssertEqual(TR064Diagnosis.verdict(diagnostics: d, error: FritzError.unauthorized), .rejected)
    }

    func testUnauthorizedWithoutAnsweredChallengeIsAppSide() {
        let d = diag(trust, .response(status: 401, authenticate: D.parseAuthenticate(digestHeader), fault: nil))
        XCTAssertEqual(TR064Diagnosis.verdict(diagnostics: d, error: FritzError.unauthorized), .credentialsNotSent)
        XCTAssertEqual(d.shortSummary, "HTTP 401 no auth challenge answered")
    }

    func testFault606LacksRights() {
        let d = diag(offered, .response(status: 500, authenticate: nil, fault: .init(code: "606", description: "Action not authorized")))
        XCTAssertEqual(TR064Diagnosis.verdict(diagnostics: d, error: FritzError.fault(code: "606", description: "Action not authorized")),
                       .lacksRights)
        XCTAssertEqual(d.shortSummary, "HTTP 500, SOAP fault 606")
    }

    func testOtherFault() {
        let d = diag(offered, .response(status: 500, authenticate: nil, fault: .init(code: "820", description: "Internal Error")))
        XCTAssertEqual(TR064Diagnosis.verdict(diagnostics: d, error: nil), .fault(code: "820", description: "Internal Error"))
    }

    func testPinRejected() {
        let d = diag(.serverTrust(decision: .reject, fingerprintPrefix: "deadbeef"),
                     .urlError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, description: "cancelled"))
        XCTAssertEqual(TR064Diagnosis.verdict(diagnostics: d, error: FritzError.certificateChanged), .tlsOrPin)
        XCTAssertEqual(d.shortSummary, "certificate pin rejected")
    }

    func testURLErrors() {
        func v(_ code: Int) -> TR064Verdict {
            TR064Diagnosis.verdict(diagnostics: diag(.urlError(domain: NSURLErrorDomain, code: code, description: "x")),
                                   error: URLError(URLError.Code(rawValue: code)))
        }
        XCTAssertEqual(v(NSURLErrorTimedOut), .unreachable)
        XCTAssertEqual(v(NSURLErrorCannotFindHost), .unreachable)
        XCTAssertEqual(v(NSURLErrorCannotConnectToHost), .tr064Disabled)
        XCTAssertEqual(v(NSURLErrorSecureConnectionFailed), .tlsOrPin)
    }

    func testHTTP500WithoutFault() {
        let d = diag(offered, .response(status: 500, authenticate: nil, fault: nil))
        XCTAssertEqual(TR064Diagnosis.verdict(diagnostics: d, error: FritzError.malformedXML), .http(500))
    }

    func testNotConfigured() {
        XCTAssertEqual(TR064Diagnosis.verdict(diagnostics: nil, error: FritzError.notConfigured), .notConfigured)
    }
}

final class SanitizationTests: XCTestCase {
    private func assertClean(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for secret in [secretUser, secretPassword, secretNonce, secretDigest, "OPAQUE42", "sid=", "SESSION99", "Authorization",
                       "cnonce", "nonce"] {
            XCTAssertFalse(text.contains(secret), "diagnostics leak \(secret): \(text)", file: file, line: line)
        }
    }

    func testParseAuthenticateKeepsOnlySafeFields() {
        let h = D.parseAuthenticate(digestHeader)
        XCTAssertEqual(h, .init(scheme: "Digest", realm: "HTTPS Access", algorithm: "MD5", qop: "auth"))
        XCTAssertEqual(D.parseAuthenticate("Basic realm=\"x, y\", charset=\"UTF-8\""), .init(scheme: "Basic", realm: "x, y"))
        XCTAssertNil(D.parseAuthenticate(nil))
    }

    func testPureBuildersDropSecrets() {
        var req = URLRequest(url: URL(string: "https://\(secretUser):\(secretPassword)@192.168.65.1:49443/upnp/control/x_contact?sid=SESSION99")!)
        req.httpMethod = "POST"
        req.setValue("\"urn:dslforum-org:service:X_AVM-DE_OnTel:1#GetPhonebookList\"", forHTTPHeaderField: "SOAPAction")
        req.setValue("Digest username=\"\(secretUser)\", nonce=\"\(secretNonce)\", response=\"\(secretDigest)\", cnonce=\"c1\"",
                     forHTTPHeaderField: "Authorization")
        req.httpBody = Data("<NewPassword>\(secretPassword)</NewPassword>".utf8)
        let label = D.requestLabel(req)
        XCTAssertEqual(label, "POST /upnp/control/x_contact GetPhonebookList")

        let response = D.responseEvent(status: 500, headers: ["WWW-Authenticate": digestHeader, "Authorization": "Digest username=\"\(secretUser)\""],
                                       body: faultBody("606", "Action not authorized", extra: "<user>\(secretUser)</user><pw>\(secretPassword)</pw>"))
        let unauthorized = D.responseEvent(status: 401, headers: ["www-authenticate": digestHeader], body: Data(secretPassword.utf8))
        let d = D(request: label, events: [
            .serverTrust(decision: .accept, fingerprintPrefix: "1a2b3c4d"),
            .authChallenge(method: .digest, realm: "HTTPS Access", algorithm: "MD5", qop: "auth", previousFailureCount: 0,
                           answered: .credentialOffered),
            unauthorized, response,
        ])
        XCTAssertEqual(response, .response(status: 500, authenticate: .init(scheme: "Digest", realm: "HTTPS Access", algorithm: "MD5", qop: "auth"),
                                           fault: .init(code: "606", description: "Action not authorized")))
        let check = TR064LoginCheck(verdict: TR064Diagnosis.verdict(diagnostics: d, error: nil), diagnostics: d, errorDescription: nil)
        assertClean(check.text)
        assertClean(d.shortSummary ?? "")
        XCTAssertTrue(check.text.contains("SOAP fault 606: Action not authorized"))
        XCTAssertTrue(check.text.contains("realm=\"HTTPS Access\" algorithm=MD5 qop=auth"))
    }

    func testTransportRecordsSanitizedDiagnosticsFor401() async throws {
        StubProtocol.mode = .plain401
        let transport = makeTransport()
        defer { transport.invalidate() }
        let client = FritzTR064Client(host: "192.168.65.1", transport: transport)
        let check = await client.checkLogin()
        let d = try XCTUnwrap(client.lastDiagnostics)
        XCTAssertEqual(d.request, "POST /upnp/control/x_contact GetPhonebookList")
        XCTAssertEqual(d.events, [.response(status: 401, authenticate: .init(scheme: "Digest", realm: "HTTPS Access", algorithm: "MD5", qop: "auth"),
                                            fault: nil)])
        XCTAssertEqual(check.verdict, .credentialsNotSent)
        XCTAssertEqual(check.model, "FRITZ!Box 6591 Cable")
        XCTAssertEqual(check.firmware, "164.08.25")
        assertClean(check.text)
    }

    /// URLSession routes the Digest challenge to the transport's task-level delegate method, which offers the
    /// credentials and records it. (A URLProtocol stub never learns the session's answer, so the request then
    /// times out; only the routing and the recorded event are checked here.)
    func testSessionRoutesDigestChallengeToTaskDelegate() async throws {
        StubProtocol.mode = .challenge
        let transport = makeTransport(timeout: 1)
        defer { transport.invalidate() }
        let check = await FritzTR064Client(host: "192.168.65.1", transport: transport).checkLogin()
        guard case .authChallenge(.digest, "HTTPS Access", "MD5", "auth", 0, .credentialOffered)? = check.diagnostics?.events.first else {
            return XCTFail("expected an answered Digest challenge: \(check.text)")
        }
        assertClean(check.text)
    }

    /// The challenge handler offers the configured credentials once, then refuses (reported as a rejected login).
    func testChallengeHandlerOffersCredentialsOnce() throws {
        let transport = makeTransport(timeout: 1)
        defer { transport.invalidate() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://192.168.65.1:49443/upnp/control/x_contact")!)
        let space = URLProtectionSpace(host: "192.168.65.1", port: 49443, protocol: "https", realm: "HTTPS Access",
                                       authenticationMethod: NSURLAuthenticationMethodHTTPDigest)
        let unauthorized = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 401, httpVersion: "HTTP/1.1",
                                           headerFields: ["WWW-Authenticate": digestHeader])
        let sender = NullSender()
        var answers: [(URLSession.AuthChallengeDisposition, URLCredential?)] = []
        for failures in 0...1 {
            let c = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: failures,
                                               failureResponse: unauthorized, error: nil, sender: sender)
            transport.urlSession(session, task: task, didReceive: c) { answers.append(($0, $1)) }
        }
        XCTAssertEqual(answers.map(\.0), [.useCredential, .cancelAuthenticationChallenge])
        XCTAssertEqual(answers.first?.1?.user, secretUser)
        XCTAssertEqual(answers.first?.1?.password, secretPassword)
        XCTAssertNil(answers.last?.1)
    }

    private func makeTransport(timeout: TimeInterval = 15) -> URLSessionTransport {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]; cfg.timeoutIntervalForRequest = timeout
        return URLSessionTransport(username: secretUser, password: secretPassword, pins: MemoryPins(), configuration: cfg)
    }
}

private final class MemoryPins: PinStore, @unchecked Sendable {
    var value: String?
    func load() -> String? { value }
    func save(_ fingerprint: String) { value = fingerprint }
}

private final class NullSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

/// Fakes the FRITZ!Box without any network access.
private final class StubProtocol: URLProtocol, URLAuthenticationChallengeSender, @unchecked Sendable {
    enum Mode { case plain401, challenge }
    nonisolated(unsafe) static var mode: Mode = .plain401

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private func reply(_ status: Int, headers: [String: String] = [:], body: Data) {
        let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    private var unauthorized: HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1",
                        headerFields: ["WWW-Authenticate": digestHeader])!
    }
    private func send401() {
        client?.urlProtocol(self, didReceive: unauthorized, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<html>401 \(secretNonce)</html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    private func ok() {
        reply(200, body: Data("""
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <u:GetPhonebookListResponse xmlns:u="urn:dslforum-org:service:X_AVM-DE_OnTel:1"><NewPhonebookList>0</NewPhonebookList>\
        </u:GetPhonebookListResponse></s:Body></s:Envelope>
        """.utf8))
    }

    override func startLoading() {
        if request.url?.path == "/tr64desc.xml" {
            return reply(200, body: Data("""
            <?xml version="1.0"?><root><device><modelName>FRITZ!Box 6591 Cable</modelName><serialNumber>SERIAL</serialNumber></device>\
            <systemVersion><Display>164.08.25</Display></systemVersion></root>
            """.utf8))
        }
        switch Self.mode {
        case .plain401: send401()
        case .challenge: issueChallenge(previousFailures: 0)
        }
    }

    private func issueChallenge(previousFailures: Int) {
        let space = URLProtectionSpace(host: request.url!.host!, port: request.url!.port ?? 443, protocol: "https",
                                       realm: "HTTPS Access", authenticationMethod: NSURLAuthenticationMethodHTTPDigest)
        let c = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: previousFailures,
                                           failureResponse: unauthorized, error: nil, sender: self)
        client?.urlProtocol(self, didReceive: c)
    }

    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) { ok() }
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) { send401() }
    func cancel(_ challenge: URLAuthenticationChallenge) {
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) { send401() }
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) { send401() }
}
