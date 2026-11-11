import Foundation
import PhoneCore

public enum FritzError: Error, Equatable {
    case malformedXML, unauthorized, certificateChanged
    case http(Int)
    case fault(code: String, description: String)
    case missingField(String)
}

public enum PhoneBookParser {
    public static func parse(_ data: Data) throws -> [Contact] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? FritzError.malformedXML }
        return delegate.contacts
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var contacts: [Contact] = []
        private var text = ""
        private var name = "", uid = "", numberType = ""
        private var numbers: [PhoneNumber] = []
        private var inContact = false

        func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if el == "contact" { inContact = true; name = ""; uid = ""; numbers = [] }
            if el == "number" { numberType = attributes["type"] ?? "" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch el {
            case "realName" where inContact: name = t
            case "uniqueid": uid = t
            case "number": if !t.isEmpty { numbers.append(PhoneNumber(number: t, type: numberType)) }
            case "contact":
                inContact = false
                contacts.append(Contact(id: uid.isEmpty ? String(contacts.count) : uid, name: name, numbers: numbers))
            default: break
            }
        }
    }
}
