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
}
