// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation

public enum SOAP {
    public static let onTelService = "urn:dslforum-org:service:X_AVM-DE_OnTel:1"

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    public static func envelope(service: String, action: String, arguments: [(String, String)]) -> Data {
        let args = arguments.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        return Data("""
        <?xml version="1.0" encoding="utf-8"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body><u:\(action) xmlns:u="\(service)">\(args)</u:\(action)></s:Body></s:Envelope>
        """.utf8)
    }

    /// Returns every leaf element's text keyed by element name; throws `FritzError.fault` for SOAP faults.
    public static func parseResponse(_ data: Data) throws -> [String: String] {
        let d = Delegate()
        let p = XMLParser(data: data)
        p.delegate = d
        guard p.parse() else { throw p.parserError ?? FritzError.malformedXML }
        if let code = d.leaves["errorCode"] {
            throw FritzError.fault(code: code, description: d.leaves["errorDescription"] ?? "")
        }
        return d.leaves
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var leaves: [String: String] = [:]
        private var text = "", hadChild = false
        private var stack: [Bool] = []   // whether each open element has had children
        func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if !stack.isEmpty { stack[stack.count - 1] = true }
            stack.append(false); text = ""
        }
        func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }
        func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
            let hadChildren = stack.popLast() ?? false
            if !hadChildren { leaves[el.split(separator: ":").last.map(String.init) ?? el] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            text = ""
        }
    }
}
