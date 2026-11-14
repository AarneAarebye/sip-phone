// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import XCTest
import PhoneCore
@testable import FritzTR064

private func reply(_ action: String, _ fields: [String: String]) -> Data {
    let body = fields.map { "<\($0.key)>\(SOAP.escape($0.value))</\($0.key)>" }.joined()
    return Data("""
    <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
    <u:\(action)Response xmlns:u="urn:dslforum-org:service:X_AVM-DE_OnTel:1">\(body)</u:\(action)Response>\
    </s:Body></s:Envelope>
    """.utf8)
}

private func action(_ r: URLRequest) -> String {
    (r.value(forHTTPHeaderField: "SOAPAction") ?? "").split(separator: "#").last.map { $0.dropLast() }.map(String.init) ?? ""
}

final class EditingTests: XCTestCase {
    func testParserKeepsEntryID() throws {
        let data = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "phonebook", withExtension: "xml", subdirectory: "Fixtures")))
        XCTAssertEqual(try PhoneBookParser.parse(data).map(\.entryID), ["11", "12"])
        let none = Data("<phonebooks><phonebook><contact><person><realName>A</realName></person></contact></phonebook></phonebooks>".utf8)
        XCTAssertNil(try PhoneBookParser.parse(none).first?.entryID)
    }

    func testLoadContactsCarriesEntryIDAndReadOnly() async throws {
        let book = Data("<phonebooks><phonebook name=\"X\"><contact><person><realName>A</realName></person><uniqueid>5</uniqueid></contact></phonebook></phonebooks>".utf8)
        let transport = FakeTransport { req in
            switch action(req) {
            case "GetPhonebookList": return reply("GetPhonebookList", ["NewPhonebookList": "0,1"])
            case "GetPhonebook":
                let one = String(decoding: req.httpBody ?? Data(), as: UTF8.self).contains(">1<")
                return reply("GetPhonebook", ["NewPhonebookURL": "https://fritz.box:49443/pb.xml", "NewPhonebookExtraID": one ? "google" : ""])
            default: return book
            }
        }
        let cs = try await FritzTR064Client(host: "fritz.box", transport: transport).loadContacts()
        XCTAssertEqual(cs.map(\.entryID), ["5", "5"])
        XCTAssertEqual(cs.map(\.phoneBookReadOnly), [false, true])
    }

    func testSetEntrySendsEscapedDataAndEmptyIDForCreate() async throws {
        let transport = FakeTransport { _ in reply("SetPhonebookEntryUID", ["NewPhonebookEntryUniqueID": "42"]) }
        let client = FritzTR064Client(host: "fritz.box", transport: transport)
        let draft = ContactDraft(name: "A<b>&\"c\"", numbers: [PhoneNumber(number: "030", type: "home")])
        try await PhoneBookEditor(client).create(bookID: "2", draft: draft)
        let req = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(action(req), "SetPhonebookEntryUID")
        XCTAssertEqual(req.url?.path, "/upnp/control/x_contact")
        let body = String(decoding: try XCTUnwrap(req.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("<NewPhonebookID>2</NewPhonebookID>"))
        XCTAssertFalse(body.contains("NewPhonebookEntryID"), "SetPhonebookEntryUID has no entry id argument")
        XCTAssertFalse(body.contains("<realName>"), "entry XML must be escaped inside the SOAP element")
        // Round trip: unescaping the SOAP argument gives well-formed entry XML with the original name.
        let args = try SOAP.parseResponse(try XCTUnwrap(req.httpBody))
        let entry = try XMLDocument(xmlString: try XCTUnwrap(args["NewPhonebookEntryData"]), options: [])
        XCTAssertEqual(try entry.nodes(forXPath: "//realName").first?.stringValue, "A<b>&\"c\"")
    }

    func testEntryDataAndDeleteRequests() async throws {
        let transport = FakeTransport { req in
            action(req) == "GetPhonebookEntryUID"
                ? reply("GetPhonebookEntryUID", ["NewPhonebookEntryData": "<contact><uniqueid>7</uniqueid></contact>"])
                : reply("DeletePhonebookEntryUID", [:])
        }
        let client = FritzTR064Client(host: "fritz.box", transport: transport)
        let data = try await client.entryData(bookID: "0", entryID: "7")
        XCTAssertEqual(data, "<contact><uniqueid>7</uniqueid></contact>")
        try await client.deleteEntry(bookID: "0", entryID: "7")
        let body = String(decoding: try XCTUnwrap(transport.requests.last?.httpBody), as: UTF8.self)
        XCTAssertEqual(action(try XCTUnwrap(transport.requests.last)), "DeletePhonebookEntryUID")
        XCTAssertTrue(body.contains("<NewPhonebookEntryUniqueID>7</NewPhonebookEntryUniqueID>"))
        XCTAssertFalse(body.contains("<NewPhonebookEntryID>"), "plain *Entry actions take a list index, not the uniqueid")
    }

    func testRefusedWritesBecomeReadableErrors() async {
        let refusals: [Error] = [FritzError.unauthorized, FritzError.http(500), FritzError.fault(code: "606", description: "x")]
        for failure in refusals {
            let client = FritzTR064Client(host: "fritz.box", transport: FakeTransport { _ in throw failure })
            do { try await client.deleteEntry(bookID: "0", entryID: "1"); XCTFail() }
            catch let e as PhoneBookEditError {
                guard case .refused(let m) = e else { return XCTFail("\(e)") }
                XCTAssertTrue(m.contains("right to edit phone books"), m)
            } catch { XCTFail("\(error)") }
        }
    }

    func testCertificateChangedIsNotMaskedAsRefusal() async {
        let client = FritzTR064Client(host: "fritz.box", transport: FakeTransport { _ in throw FritzError.certificateChanged })
        do { try await client.deleteEntry(bookID: "0", entryID: "1"); XCTFail() }
        catch { XCTAssertEqual(error as? FritzError, .certificateChanged) }
    }

    func testMoveEndToEndAgainstFakeBox() async throws {
        let transport = FakeTransport { req in
            switch action(req) {
            case "GetPhonebookEntryUID":
                return reply("GetPhonebookEntryUID", ["NewPhonebookEntryData": "<contact><person><realName>A</realName></person><uniqueid>7</uniqueid></contact>"])
            case "SetPhonebookEntryUID": return reply("SetPhonebookEntryUID", ["NewPhonebookEntryUniqueID": "1"])
            default: return reply("DeletePhonebookEntryUID", [:])
            }
        }
        let client = FritzTR064Client(host: "fritz.box", transport: transport)
        try await PhoneBookEditor(client).transfer(from: "0", entryID: "7", to: "1", mode: .move)
        XCTAssertEqual(transport.requests.map(action), ["GetPhonebookEntryUID", "SetPhonebookEntryUID", "DeletePhonebookEntryUID"])
    }

    /// Regression for the live 713: the edit must address the entry by its uniqueid through the UID actions,
    /// and the written XML must carry that same <uniqueid> (AVM TR-064 Contact SCPD, 2.15/2.17).
    func testEditUsesUniqueIDActionsAndKeepsUniqueIDInData() async throws {
        let stored = "<contact><category>0</category><person><realName>Old</realName></person>"
            + "<telephony nid=\"1\"><number type=\"home\" prio=\"1\" id=\"0\">111</number></telephony><uniqueid>28</uniqueid></contact>"
        let transport = FakeTransport { req in
            action(req) == "GetPhonebookEntryUID" ? reply("GetPhonebookEntryUID", ["NewPhonebookEntryData": stored])
                                                  : reply("SetPhonebookEntryUID", ["NewPhonebookEntryUniqueID": "28"])
        }
        let client = FritzTR064Client(host: "fritz.box", transport: transport)
        let draft = ContactDraft(name: "New", numbers: [PhoneNumber(number: "111", type: "home"), PhoneNumber(number: "222", type: "mobile")])
        try await PhoneBookEditor(client).update(bookID: "3", entryID: "28", draft: draft)
        XCTAssertEqual(transport.requests.map(action), ["GetPhonebookEntryUID", "SetPhonebookEntryUID"])
        let get = String(decoding: try XCTUnwrap(transport.requests.first?.httpBody), as: UTF8.self)
        XCTAssertTrue(get.contains("<NewPhonebookID>3</NewPhonebookID>"))
        XCTAssertTrue(get.contains("<NewPhonebookEntryUniqueID>28</NewPhonebookEntryUniqueID>"))
        let setBody = try XCTUnwrap(transport.requests.last?.httpBody)
        let args = try SOAP.parseResponse(setBody)
        XCTAssertEqual(args["NewPhonebookID"], "3")
        let entry = try XMLDocument(xmlString: try XCTUnwrap(args["NewPhonebookEntryData"]), options: [])
        XCTAssertEqual(try entry.nodes(forXPath: "//uniqueid").map(\.stringValue), ["28"])
        XCTAssertEqual(try entry.nodes(forXPath: "//number").count, 2)
    }

    func testFault713BecomesClearErrorAndNothingIsWritten() async {
        let fault = Data("""
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><faultcode>s:Client</faultcode>\
        <faultstring>UPnPError</faultstring><detail><UPnPError xmlns="urn:dslforum-org:control-1-0"><errorCode>713</errorCode>\
        <errorDescription>SpecifiedArrayIndexInvalid</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>
        """.utf8)
        let transport = FakeTransport { _ in fault }
        let client = FritzTR064Client(host: "fritz.box", transport: transport)
        let draft = ContactDraft(name: "A", numbers: [PhoneNumber(number: "1", type: "home")])
        do { try await PhoneBookEditor(client).update(bookID: "3", entryID: "28", draft: draft); XCTFail() }
        catch { XCTAssertEqual(error as? PhoneBookEditError, .entryNotFound) }
        XCTAssertEqual(transport.requests.map(action), ["GetPhonebookEntryUID"], "no write after a failed read")
        do { try await client.deleteEntry(bookID: "3", entryID: "28"); XCTFail() }
        catch { XCTAssertEqual(error as? PhoneBookEditError, .entryNotFound) }
    }

    func testEmptyEntryDataIsNotFoundNotGarbage() async {
        let client = FritzTR064Client(host: "fritz.box", transport: FakeTransport { _ in reply("GetPhonebookEntryUID", ["NewPhonebookEntryData": ""]) })
        do { _ = try await client.entryData(bookID: "0", entryID: "1"); XCTFail() }
        catch { XCTAssertEqual(error as? PhoneBookEditError, .entryNotFound) }
    }
}
