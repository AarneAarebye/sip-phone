import XCTest
import PhoneCore
@testable import FritzTR064

final class FakeTransport: HTTPTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    let handler: (URLRequest) throws -> Data
    init(_ handler: @escaping (URLRequest) throws -> Data) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> Data { requests.append(request); return try handler(request) }
}

private func soapReply(_ action: String, _ fields: [String: String]) -> Data {
    let body = fields.map { "<\($0.key)>\($0.value)</\($0.key)>" }.joined()
    return Data("""
    <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
    <u:\(action)Response xmlns:u="urn:dslforum-org:service:X_AVM-DE_OnTel:1">\(body)</u:\(action)Response>\
    </s:Body></s:Envelope>
    """.utf8)
}

final class ClientTests: XCTestCase {
    func testEnvelopeEscapesAndNamesAction() {
        let xml = String(decoding: SOAP.envelope(service: "svc:1", action: "GetX", arguments: [("NewA", "a<b&c")]), as: UTF8.self)
        XCTAssertTrue(xml.contains("<u:GetX xmlns:u=\"svc:1\">"))
        XCTAssertTrue(xml.contains("<NewA>a&lt;b&amp;c</NewA>"))
    }

    func testParseResponseReturnsLeafFields() throws {
        let fields = try SOAP.parseResponse(soapReply("GetPhonebookList", ["NewPhonebookList": "0,1"]))
        XCTAssertEqual(fields["NewPhonebookList"], "0,1")
    }

    func testParseResponseThrowsOnFault() {
        let fault = Data("""
        <s:Envelope xmlns:s="x"><s:Body><s:Fault><detail><UPnPError><errorCode>606</errorCode>\
        <errorDescription>Action not authorized</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>
        """.utf8)
        XCTAssertThrowsError(try SOAP.parseResponse(fault)) {
            XCTAssertEqual($0 as? FritzError, .fault(code: "606", description: "Action not authorized"))
        }
    }

    func testLoadContactsMergesPhonebooksWithPrefixedIds() async throws {
        let book = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "phonebook", withExtension: "xml", subdirectory: "Fixtures")))
        let transport = FakeTransport { req in
            let action = req.value(forHTTPHeaderField: "SOAPAction") ?? ""
            if action.hasSuffix("#GetPhonebookList\"") { return soapReply("GetPhonebookList", ["NewPhonebookList": "0,1"]) }
            if action.hasSuffix("#GetPhonebook\"") {
                return soapReply("GetPhonebook", ["NewPhonebookURL": "https://fritz.box:49443/phonebook\(req.httpBody.map { String(decoding: $0, as: UTF8.self).contains(">1<") ? 1 : 0 } ?? 0).xml"])
            }
            return book   // GET of the phonebook URL
        }
        let client = FritzTR064Client(host: "fritz.box", transport: transport)
        let contacts = try await client.loadContacts()
        XCTAssertEqual(contacts.count, 4)
        XCTAssertEqual(contacts.map(\.id), ["0-11", "0-12", "1-11", "1-12"])
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "SOAPAction"),
                       "\"urn:dslforum-org:service:X_AVM-DE_OnTel:1#GetPhonebookList\"")
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://fritz.box:49443/upnp/control/x_contact")
    }

    func testLoadCallListAppendsMax() async throws {
        let list = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "calllist", withExtension: "xml", subdirectory: "Fixtures")))
        let transport = FakeTransport { req in
            (req.value(forHTTPHeaderField: "SOAPAction") ?? "").hasSuffix("#GetCallList\"")
                ? soapReply("GetCallList", ["NewCallListURL": "https://fritz.box:49443/calllist.lua?sid=abc"])
                : list
        }
        let calls = try await FritzTR064Client(host: "fritz.box", transport: transport).loadCallList()
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(transport.requests.last?.url?.absoluteString, "https://fritz.box:49443/calllist.lua?sid=abc&max=200")
    }

    func testCertificatePinningDecisions() {
        XCTAssertEqual(CertificatePinning.decide(fingerprint: "aa", stored: nil), .acceptAndStore)
        XCTAssertEqual(CertificatePinning.decide(fingerprint: "aa", stored: "aa"), .accept)
        XCTAssertEqual(CertificatePinning.decide(fingerprint: "bb", stored: "aa"), .reject)
    }

    // MARK: Final review fixes (I2)

    func testSOAPDownloadURLsAreRebasedOntoConfiguredHTTPSBase() {
        let base = URL(string: "https://fritz.box:49443")!
        let cases: [(String, String?, String)] = [
            ("https://fritz.box:49443/phonebook.lua?sid=1&pbid=0", nil, "https://fritz.box:49443/phonebook.lua?sid=1&pbid=0"),
            ("http://fritz.box:49000/phonebook.lua?sid=1", nil, "https://fritz.box:49443/phonebook.lua?sid=1"),
            ("https://evil.example/steal?sid=1", nil, "https://fritz.box:49443/steal?sid=1"),
            ("http://user:pw@192.168.178.1:80/calllist.lua?sid=abc#frag", "max=200", "https://fritz.box:49443/calllist.lua?sid=abc&max=200"),
            ("/calllist.lua", "max=200", "https://fritz.box:49443/calllist.lua?max=200"),
        ]
        for (reply, extra, expected) in cases {
            XCTAssertEqual(FritzTR064Client.rebase(reply, onto: base, extraQuery: extra)?.absoluteString, expected, reply)
        }
        XCTAssertNil(FritzTR064Client.rebase("", onto: base))
    }

    func testForeignHostPhonebookURLIsNotFollowed() async throws {
        let book = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "phonebook", withExtension: "xml", subdirectory: "Fixtures")))
        let transport = FakeTransport { req in
            let action = req.value(forHTTPHeaderField: "SOAPAction") ?? ""
            if action.hasSuffix("#GetPhonebookList\"") { return soapReply("GetPhonebookList", ["NewPhonebookList": "0"]) }
            if action.hasSuffix("#GetPhonebook\"") { return soapReply("GetPhonebook", ["NewPhonebookURL": "http://evil.example:80/pb.lua?sid=9"]) }
            return book
        }
        _ = try await FritzTR064Client(host: "fritz.box", transport: transport).loadContacts()
        XCTAssertEqual(transport.requests.last?.url?.absoluteString, "https://fritz.box:49443/pb.lua?sid=9")
    }

    func testCredentialsOnlyOverSecureSpaceAndOnce() {
        XCTAssertTrue(CertificatePinning.shouldSendCredentials(receivesCredentialSecurely: true, previousFailureCount: 0))
        XCTAssertFalse(CertificatePinning.shouldSendCredentials(receivesCredentialSecurely: false, previousFailureCount: 0))
        XCTAssertFalse(CertificatePinning.shouldSendCredentials(receivesCredentialSecurely: true, previousFailureCount: 1))
    }

    func testErrorsHaveReadableMessages() {
        let changed = FritzError.certificateChanged.localizedDescription
        XCTAssertTrue(changed.contains("certificate changed"), changed)
        XCTAssertTrue(changed.contains("Forget pinned certificate"), changed)
        XCTAssertEqual(FritzError.http(503).localizedDescription, "The FRITZ!Box answered with HTTP status 503.")
        XCTAssertTrue(FritzError.unauthorized.localizedDescription.contains("user name or password"))
        XCTAssertEqual(FritzError.fault(code: "606", description: "Action not authorized").localizedDescription,
                       "The FRITZ!Box refused the request (606: Action not authorized).")
    }

    func testFingerprintFormatAndProbeVerdict() {
        let der = Data("cert".utf8)
        let fp = CertificatePinning.fingerprint(ofDER: der)
        XCTAssertEqual(fp, "06298432e8066b29e2223bcc23aa9504b56ae508fabf3435508869b9c3190e22")   // shasum -a 256 format
        XCTAssertTrue(CertificatePinning.probeMatchesPin(leafDER: der, pinned: fp))
        XCTAssertTrue(CertificatePinning.probeMatchesPin(leafDER: der, pinned: fp.uppercased()))
        XCTAssertFalse(CertificatePinning.probeMatchesPin(leafDER: Data("other".utf8), pinned: fp))
        XCTAssertFalse(CertificatePinning.probeMatchesPin(leafDER: nil, pinned: fp))
        XCTAssertFalse(CertificatePinning.probeMatchesPin(leafDER: der, pinned: ""))
    }
}
