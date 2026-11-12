import Foundation
import PhoneCore

public final class FritzTR064Client: PhoneBookService, @unchecked Sendable {
    public static let defaultPort = 49443
    private let base: URL
    private let transport: HTTPTransport

    public init(host: String, port: Int = FritzTR064Client.defaultPort, transport: HTTPTransport) {
        self.base = URL(string: "https://\(host):\(port)")!
        self.transport = transport
    }

    private func call(_ action: String, _ args: [(String, String)] = []) async throws -> [String: String] {
        var req = URLRequest(url: base.appendingPathComponent("upnp/control/x_contact"))
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(SOAP.onTelService)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        req.httpBody = SOAP.envelope(service: SOAP.onTelService, action: action, arguments: args)
        return try SOAP.parseResponse(try await transport.send(req))
    }

    public func loadContacts() async throws -> [Contact] {
        let list = try await call("GetPhonebookList")["NewPhonebookList"] ?? "0"
        var all: [Contact] = []
        for id in list.split(separator: ",").map(String.init) {
            let reply = try await call("GetPhonebook", [("NewPhonebookID", id)])
            guard let s = reply["NewPhonebookURL"], let url = URL(string: s) else { throw FritzError.missingField("NewPhonebookURL") }
            let contacts = try PhoneBookParser.parse(try await transport.send(URLRequest(url: url)))
            all += contacts.map { Contact(id: "\(id)-\($0.id)", name: $0.name, numbers: $0.numbers) }
        }
        return all
    }

    public func loadCallList() async throws -> [CallRecord] {
        let reply = try await call("GetCallList")
        guard let s = reply["NewCallListURL"], let url = URL(string: s + "&max=200") else { throw FritzError.missingField("NewCallListURL") }
        return try CallListParser.parse(try await transport.send(URLRequest(url: url)))
    }
}
