# Fritz!Box SIP Phone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu bar app that registers as a SIP extension on a Fritz!Box, places and receives calls, shows the Fritz!Box phone book and call list, and brings up a WireGuard VPN automatically when away from home.

**Architecture:** A local Swift package `PhoneKit` holds all logic behind protocols (`PhoneCore` = models, protocols, `AppCore` orchestrator; `FritzTR064` = phone book/call list client; `PJBridge` + `SIPEngine` = PJSIP wrapper; `VPN` = WireGuard control). A thin XcodeGen-generated app target holds SwiftUI views, and a `PacketTunnel` app-extension target runs WireGuardKit. `AppCore` is fully unit-tested with fakes.

**Tech Stack:** Swift 5.9, SwiftUI (`MenuBarExtra`, `@Observable`), XCTest, PJSIP 2.15 (pjsua2, C++/ObjC++), WireGuardKit (NetworkExtension), TR-064 SOAP over HTTPS via URLSession, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-11-sip-phone-design.md`

## Global Constraints

- Native macOS app, SwiftUI, menu bar mode; secrets (SIP password, TR-064 password, WireGuard config/private key) only in the Keychain, never in UserDefaults, files, or logs.
- SIP/audio via PJSIP (pjsua2) built as an xcframework, wrapped by a thin Objective-C++ bridge; codecs G.722, PCMA, PCMU only.
- Phone book and call list via Fritz!Box TR-064 over HTTPS in plain Swift (no third-party library); self-signed certificate pinned on first use, warn on change.
- VPN is WireGuard through a NetworkExtension packet-tunnel provider (WireGuardKit); the app starts it only when the Fritz!Box is unreachable and stops it on quit only if the app started it.
- `SIPEngine`, `FritzTR064` and `VPNManager` sit behind protocols; the UI never talks to PJSIP or the network directly.
- While on AC power and the app runs, hold an `IOPMAssertion` preventing idle system sleep (setting can turn it off); on battery release it. A sleeping Mac cannot ring; missed calls appear in the call list after wake.
- v1 scope: dial, receive (notification with caller name, Answer/Decline), searchable read-only phone book, call history, menu bar mode, mute and DTMF, automatic VPN, launch at login. **Out:** phone book editing, hold, video, multiple accounts, push wake-ups.
- Plan-level decisions (not in the spec): macOS 14.0 deployment target; PJSIP built for arm64 only; XcodeGen generates the Xcode project; HTTP digest authentication is handled by `URLSession`'s built-in challenge handling (no hand-written digest code).
- Every commit message ends with the line `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Tests: `cd Packages/PhoneKit && swift test`. App build: `xcodegen && xcodebuild -scheme FritzPhone -destination 'platform=macOS' build`.

## File Structure

```
.gitignore
project.yml                                   XcodeGen: app + PacketTunnel targets
App/                                          SwiftUI app target
  FritzPhoneApp.swift                         @main, MenuBarExtra, Settings scene
  AppDelegate.swift                           owns AppEnvironment, call window, notifications
  AppEnvironment.swift                        builds real implementations, wires AppCore
  Views/{MainView,ContactsView,HistoryView,DialPadView,InCallView,SettingsView}.swift
  Info.plist, FritzPhone.entitlements
PacketTunnel/                                 NetworkExtension app extension
  PacketTunnelProvider.swift, Info.plist, PacketTunnel.entitlements
scripts/build-pjsip.sh                        builds PJSIP.xcframework
Packages/PhoneKit/
  Package.swift
  Sources/PhoneCore/{Models,NumberMatcher,Protocols,Settings,Secrets,ContactCache,AppCore}.swift
  Sources/FritzTR064/{PhoneBookParser,CallListParser,SOAP,Transport,FritzTR064Client}.swift
  Sources/PJBridge/{include/PJBridge.h,PJBridge.mm}
  Sources/SIPEngine/PJSIPEngine.swift
  Sources/VPN/{VPNManager,FritzReachability}.swift
  Sources/System/{PowerAssertion,SystemMonitors}.swift
  Sources/fritzdump/main.swift, Sources/siptool/main.swift     (dev tools)
  Tests/{PhoneCoreTests,FritzTR064Tests}/...
```

---

### Task 1: Project skeleton

**Files:**
- Create: `.gitignore`, `project.yml`, `Packages/PhoneKit/Package.swift`, `Packages/PhoneKit/Sources/PhoneCore/Models.swift` (stub), `Packages/PhoneKit/Tests/PhoneCoreTests/SmokeTests.swift`, `App/FritzPhoneApp.swift`, `App/Info.plist`, `App/FritzPhone.entitlements`

**Interfaces:**
- Produces: SPM package `PhoneKit` with library products `PhoneCore`, `FritzTR064`; app target `FritzPhone` (menu bar only).

- [ ] **Step 1: Verify tooling**

Run: `xcodebuild -version && swift --version && brew list xcodegen go >/dev/null 2>&1; echo $?`
Expected: Xcode 15+ and Swift 5.9+. If the last number is non-zero run `brew install xcodegen go` (Go is needed later by WireGuardKit).

- [ ] **Step 2: Ask the user for their Apple Team ID and bundle prefix**

Needed for `project.yml` (`DEVELOPMENT_TEAM`, `bundleIdPrefix`). Use these values below wherever `TEAMID` and `com.example` appear.

- [ ] **Step 3: Write `.gitignore`**

```
.build/
build/
DerivedData/
*.xcodeproj
.DS_Store
Packages/PhoneKit/Frameworks/
```

- [ ] **Step 4: Write `Packages/PhoneKit/Package.swift`**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhoneKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhoneCore", targets: ["PhoneCore"]),
        .library(name: "FritzTR064", targets: ["FritzTR064"]),
    ],
    targets: [
        .target(name: "PhoneCore"),
        .target(name: "FritzTR064", dependencies: ["PhoneCore"]),
        .testTarget(name: "PhoneCoreTests", dependencies: ["PhoneCore"]),
        .testTarget(name: "FritzTR064Tests", dependencies: ["FritzTR064", "PhoneCore"],
                    resources: [.copy("Fixtures")]),
    ]
)
```

- [ ] **Step 5: Stub files so the package compiles**

`Sources/FritzTR064/Placeholder.swift`: `import PhoneCore` (single line; deleted in Task 3).
`Sources/PhoneCore/Models.swift`: `import Foundation` (replaced in Task 2).
`Tests/PhoneCoreTests/SmokeTests.swift`:

```swift
import XCTest
@testable import PhoneCore

final class SmokeTests: XCTestCase {
    func testPackageBuilds() { XCTAssertTrue(true) }
}
```
Create the empty directory `Tests/FritzTR064Tests/Fixtures` with a `.gitkeep` and a stub `Tests/FritzTR064Tests/Stub.swift` containing `import XCTest`.

- [ ] **Step 6: Run `cd Packages/PhoneKit && swift test`**

Expected: PASS (1 test).

- [ ] **Step 7: Write `project.yml`**

```yaml
name: FritzPhone
options:
  bundleIdPrefix: com.example
  deploymentTarget: { macOS: "14.0" }
settings:
  base:
    DEVELOPMENT_TEAM: TEAMID
    SWIFT_VERSION: "5.9"
packages:
  PhoneKit: { path: Packages/PhoneKit }
targets:
  FritzPhone:
    type: application
    platform: macOS
    sources: [App]
    dependencies:
      - package: PhoneKit
        product: PhoneCore
      - package: PhoneKit
        product: FritzTR064
    info:
      path: App/Info.plist
      properties:
        LSUIElement: true
        NSMicrophoneUsageDescription: "Needed to make phone calls."
    entitlements:
      path: App/FritzPhone.entitlements
      properties:
        com.apple.security.app-sandbox: true
        com.apple.security.network.client: true
        com.apple.security.device.audio-input: true
```

- [ ] **Step 8: Write `App/FritzPhoneApp.swift`**

```swift
import SwiftUI

@main
struct FritzPhoneApp: App {
    var body: some Scene {
        MenuBarExtra("Fritz Phone", systemImage: "phone") {
            Text("Fritz Phone").padding()
            Button("Quit") { NSApplication.shared.terminate(nil) }.padding([.horizontal, .bottom])
        }
        .menuBarExtraStyle(.window)
    }
}
```
`App/Info.plist` and the entitlements file are generated by XcodeGen from `project.yml`; run `xcodegen` to create them.

- [ ] **Step 9: Build the app**

Run: `xcodegen && xcodebuild -scheme FritzPhone -destination 'platform=macOS' build | tail -5`
Expected: `** BUILD SUCCEEDED **`. Launch it once: a phone icon appears in the menu bar and no Dock icon.

- [ ] **Step 10: Commit**

```bash
git add -A && git commit -m "chore: project skeleton (XcodeGen app, PhoneKit package)" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Models and number matching

**Files:**
- Create: `Packages/PhoneKit/Sources/PhoneCore/Models.swift` (replace stub), `Packages/PhoneKit/Sources/PhoneCore/NumberMatcher.swift`
- Test: `Packages/PhoneKit/Tests/PhoneCoreTests/NumberMatcherTests.swift`

**Interfaces:**
- Produces:
  - `struct PhoneNumber: Codable, Equatable, Sendable { number: String; type: String }`
  - `struct Contact: Codable, Equatable, Identifiable, Sendable { id: String; name: String; numbers: [PhoneNumber] }`
  - `enum CallRecordType: Equatable, Sendable { incoming, missed, outgoing, rejected }`
  - `struct CallRecord: Equatable, Identifiable, Sendable { id: Int; type: CallRecordType; remoteNumber: String; name: String?; date: Date; duration: TimeInterval }`
  - `protocol PhoneBookService: Sendable { func loadContacts() async throws -> [Contact]; func loadCallList() async throws -> [CallRecord] }`
  - `enum NumberMatcher { static func normalize(_:countryCode:areaCode:) -> String; static func matches(_:_:countryCode:areaCode:) -> Bool }`
  - `struct PhoneBookIndex { init(contacts:countryCode:areaCode:); func name(for number: String) -> String? }`

- [ ] **Step 1: Write the failing tests** (`NumberMatcherTests.swift`)

```swift
import XCTest
@testable import PhoneCore

final class NumberMatcherTests: XCTestCase {
    func testNormalizeInternationalAndNationalFormsAgree() {
        let expected = "49301234"
        XCTAssertEqual(NumberMatcher.normalize("+49 30 1234"), expected)
        XCTAssertEqual(NumberMatcher.normalize("030 1234"), expected)
        XCTAssertEqual(NumberMatcher.normalize("0049 30 1234"), expected)
        XCTAssertEqual(NumberMatcher.normalize("(030) 12-34"), expected)
    }
    func testNumberWithoutAreaCodeUsesConfiguredAreaCode() {
        XCTAssertEqual(NumberMatcher.normalize("1234", areaCode: "030"), "49301234")
        XCTAssertEqual(NumberMatcher.normalize("1234", areaCode: "30"), "49301234")
        XCTAssertEqual(NumberMatcher.normalize("1234"), "1234")
    }
    func testEmptyAndNonNumericNeverMatch() {
        XCTAssertEqual(NumberMatcher.normalize(""), "")
        XCTAssertEqual(NumberMatcher.normalize("anonymous"), "")
        XCTAssertFalse(NumberMatcher.matches("", ""))
    }
    func testMatches() {
        XCTAssertTrue(NumberMatcher.matches("+49 30 1234", "030 1234"))
        XCTAssertFalse(NumberMatcher.matches("030 1234", "030 1235"))
    }
    func testIndexFindsNameAcrossFormats() {
        let c = Contact(id: "1", name: "Erika", numbers: [PhoneNumber(number: "030 1234", type: "home")])
        let index = PhoneBookIndex(contacts: [c])
        XCTAssertEqual(index.name(for: "+49301234"), "Erika")
        XCTAssertNil(index.name(for: "0301235"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/PhoneKit && swift test --filter NumberMatcherTests`
Expected: FAIL (compile error: `NumberMatcher` not found).

- [ ] **Step 3: Implement `Models.swift`**

```swift
import Foundation

public struct PhoneNumber: Codable, Equatable, Sendable {
    public let number: String
    public let type: String
    public init(number: String, type: String) { self.number = number; self.type = type }
}

public struct Contact: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let numbers: [PhoneNumber]
    public init(id: String, name: String, numbers: [PhoneNumber]) { self.id = id; self.name = name; self.numbers = numbers }
}

public enum CallRecordType: Equatable, Sendable { case incoming, missed, outgoing, rejected }

public struct CallRecord: Equatable, Identifiable, Sendable {
    public let id: Int
    public let type: CallRecordType
    public let remoteNumber: String
    public let name: String?
    public let date: Date
    public let duration: TimeInterval
    public init(id: Int, type: CallRecordType, remoteNumber: String, name: String?, date: Date, duration: TimeInterval) {
        self.id = id; self.type = type; self.remoteNumber = remoteNumber; self.name = name; self.date = date; self.duration = duration
    }
}

public protocol PhoneBookService: Sendable {
    func loadContacts() async throws -> [Contact]
    func loadCallList() async throws -> [CallRecord]
}
```

- [ ] **Step 4: Implement `NumberMatcher.swift`**

```swift
import Foundation

public enum NumberMatcher {
    private static func digits(_ s: String) -> String { s.filter { ("0"..."9").contains($0) } }

    /// Digits-only form with country code, e.g. "+49 30 1234" and "030 1234" -> "49301234".
    public static func normalize(_ raw: String, countryCode: String = "49", areaCode: String? = nil) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let d = digits(trimmed)
        if d.isEmpty { return "" }
        if trimmed.hasPrefix("+") { return d }
        if d.hasPrefix("00") { return String(d.dropFirst(2)) }
        if d.hasPrefix("0") { return countryCode + d.dropFirst() }
        if let area = areaCode.map(digits), !area.isEmpty {
            let a = area.hasPrefix("0") ? String(area.dropFirst()) : area
            return countryCode + a + d
        }
        return d
    }

    public static func matches(_ a: String, _ b: String, countryCode: String = "49", areaCode: String? = nil) -> Bool {
        let na = normalize(a, countryCode: countryCode, areaCode: areaCode)
        return !na.isEmpty && na == normalize(b, countryCode: countryCode, areaCode: areaCode)
    }
}

public struct PhoneBookIndex: Sendable {
    private let names: [String: String]
    private let countryCode: String
    private let areaCode: String?

    public init(contacts: [Contact], countryCode: String = "49", areaCode: String? = nil) {
        var map: [String: String] = [:]
        for c in contacts {
            for n in c.numbers {
                let key = NumberMatcher.normalize(n.number, countryCode: countryCode, areaCode: areaCode)
                if !key.isEmpty, map[key] == nil { map[key] = c.name }
            }
        }
        self.names = map; self.countryCode = countryCode; self.areaCode = areaCode
    }

    public func name(for number: String) -> String? {
        let key = NumberMatcher.normalize(number, countryCode: countryCode, areaCode: areaCode)
        return key.isEmpty ? nil : names[key]
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `cd Packages/PhoneKit && swift test --filter NumberMatcherTests`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: contact/call models and number matching" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Phone book and call list parsers

**Files:**
- Create: `Sources/FritzTR064/PhoneBookParser.swift`, `Sources/FritzTR064/CallListParser.swift`; delete `Sources/FritzTR064/Placeholder.swift` and `Tests/FritzTR064Tests/Stub.swift`
- Create fixtures: `Tests/FritzTR064Tests/Fixtures/phonebook.xml`, `Tests/FritzTR064Tests/Fixtures/calllist.xml`
- Test: `Tests/FritzTR064Tests/ParserTests.swift`

(All paths relative to `Packages/PhoneKit`.)

**Interfaces:**
- Consumes: `Contact`, `PhoneNumber`, `CallRecord`, `CallRecordType` (Task 2).
- Produces: `enum FritzError: Error, Equatable { malformedXML, unauthorized, certificateChanged, http(Int), fault(code: String, description: String), missingField(String) }` (in `PhoneBookParser.swift`); `PhoneBookParser.parse(_ data: Data) throws -> [Contact]`; `CallListParser.parse(_ data: Data, timeZone: TimeZone = .current) throws -> [CallRecord]`.

- [ ] **Step 1: Write the fixtures**

`phonebook.xml`:
```xml
<?xml version="1.0" encoding="utf-8"?>
<phonebooks><phonebook name="Telefonbuch" owner="0">
<contact><category>0</category><person><realName>Erika Mustermann</realName></person>
<telephony nid="2"><number type="home" prio="1" id="0">030 1234567</number><number type="mobile" id="1">0171 5551234</number></telephony>
<services/><setup/><uniqueid>11</uniqueid></contact>
<contact><category>0</category><person><realName>Max Beispiel</realName></person>
<telephony nid="1"><number type="work" id="0">+49 89 998877</number></telephony>
<services/><setup/><uniqueid>12</uniqueid></contact>
</phonebook></phonebooks>
```

`calllist.xml`:
```xml
<?xml version="1.0" encoding="utf-8"?>
<root><timestamp>1700000000</timestamp>
<Call><Id>3</Id><Type>1</Type><Caller>030 1234567</Caller><Called>9876543</Called><CalledNumber>9876543</CalledNumber><Name>Erika Mustermann</Name><Numbertype>sip</Numbertype><Device>Telefon</Device><Port>10</Port><Date>11.11.26 10:15</Date><Duration>0:12</Duration><Count></Count><Path></Path></Call>
<Call><Id>2</Id><Type>2</Type><Caller>0171 5551234</Caller><Called>9876543</Called><Name></Name><Numbertype>sip</Numbertype><Device></Device><Port>10</Port><Date>10.11.26 18:02</Date><Duration>0:00</Duration></Call>
<Call><Id>1</Id><Type>3</Type><Caller>9876543</Caller><Called>089 998877</Called><Name>Max Beispiel</Name><Numbertype>sip</Numbertype><Device>Telefon</Device><Port>10</Port><Date>09.11.26 09:30</Date><Duration>1:05</Duration></Call>
</root>
```

- [ ] **Step 2: Write the failing tests** (`ParserTests.swift`)

```swift
import XCTest
import PhoneCore
@testable import FritzTR064

final class ParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testPhoneBook() throws {
        let contacts = try PhoneBookParser.parse(try fixture("phonebook"))
        XCTAssertEqual(contacts.count, 2)
        XCTAssertEqual(contacts[0].id, "11")
        XCTAssertEqual(contacts[0].name, "Erika Mustermann")
        XCTAssertEqual(contacts[0].numbers, [PhoneNumber(number: "030 1234567", type: "home"),
                                             PhoneNumber(number: "0171 5551234", type: "mobile")])
        XCTAssertEqual(contacts[1].numbers.first?.number, "+49 89 998877")
    }

    func testCallList() throws {
        let tz = TimeZone(identifier: "Europe/Berlin")!
        let calls = try CallListParser.parse(try fixture("calllist"), timeZone: tz)
        XCTAssertEqual(calls.map(\.type), [.incoming, .missed, .outgoing])
        XCTAssertEqual(calls[0].remoteNumber, "030 1234567")   // incoming -> Caller
        XCTAssertEqual(calls[0].name, "Erika Mustermann")
        XCTAssertEqual(calls[0].duration, 12 * 60)
        XCTAssertNil(calls[1].name)
        XCTAssertEqual(calls[2].remoteNumber, "089 998877")    // outgoing -> Called
        XCTAssertEqual(calls[2].duration, 3600 + 5 * 60)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: calls[0].date)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2026, 11, 11, 10, 15])
    }

    func testMalformedXMLThrows() {
        XCTAssertThrowsError(try PhoneBookParser.parse(Data("<a>".utf8)))
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `cd Packages/PhoneKit && swift test --filter ParserTests`
Expected: FAIL (compile error: `PhoneBookParser` not found).

- [ ] **Step 4: Implement `PhoneBookParser.swift`**

```swift
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
```

- [ ] **Step 5: Implement `CallListParser.swift`**

```swift
import Foundation
import PhoneCore

public enum CallListParser {
    public static func parse(_ data: Data, timeZone: TimeZone = .current) throws -> [CallRecord] {
        let delegate = Delegate(timeZone: timeZone)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? FritzError.malformedXML }
        return delegate.records
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var records: [CallRecord] = []
        private var fields: [String: String] = [:]
        private var text = ""
        private var inCall = false
        private let formatter: DateFormatter

        init(timeZone: TimeZone) {
            formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "dd.MM.yy HH:mm"
        }

        func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if el == "Call" { inCall = true; fields = [:] }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if el == "Call" { inCall = false; if let r = build() { records.append(r) } }
            else if inCall { fields[el] = t }
        }

        private func build() -> CallRecord? {
            guard let code = fields["Type"].flatMap(Int.init) else { return nil }
            let type: CallRecordType
            let remote: String?
            switch code {
            case 1, 9: type = .incoming; remote = fields["Caller"]
            case 2: type = .missed; remote = fields["Caller"]
            case 10: type = .rejected; remote = fields["Caller"]
            case 3, 11: type = .outgoing; remote = fields["Called"]
            default: return nil
            }
            guard let date = fields["Date"].flatMap(formatter.date(from:)) else { return nil }
            let parts = (fields["Duration"] ?? "0:00").split(separator: ":").compactMap { Int($0) }
            let duration = parts.count == 2 ? TimeInterval(parts[0] * 3600 + parts[1] * 60) : 0
            let name = fields["Name"].flatMap { $0.isEmpty ? nil : $0 }
            return CallRecord(id: Int(fields["Id"] ?? "") ?? records.count, type: type,
                              remoteNumber: remote ?? "", name: name, date: date, duration: duration)
        }
    }
}
```

- [ ] **Step 6: Run to verify pass**

Run: `cd Packages/PhoneKit && swift test --filter ParserTests`
Expected: PASS (3 tests).

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: TR-064 phone book and call list parsers" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 4: TR-064 client (SOAP, transport, certificate pinning) and `fritzdump` tool

**Files:**
- Create: `Sources/FritzTR064/SOAP.swift`, `Sources/FritzTR064/Transport.swift`, `Sources/FritzTR064/FritzTR064Client.swift`, `Sources/fritzdump/main.swift`
- Modify: `Package.swift` (add `fritzdump` executable target)
- Test: `Tests/FritzTR064Tests/ClientTests.swift`

**Interfaces:**
- Consumes: parsers and `FritzError` (Task 3), `PhoneBookService` (Task 2).
- Produces:
  - `protocol HTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> Data }`
  - `protocol PinStore: AnyObject, Sendable { func load() -> String?; func save(_ fingerprint: String) }`
  - `enum PinDecision { acceptAndStore, accept, reject }`; `CertificatePinning.decide(fingerprint:stored:) -> PinDecision`
  - `final class URLSessionTransport: HTTPTransport { init(username: String, password: String, pins: PinStore) }`
  - `enum SOAP { static func envelope(service:action:arguments:) -> Data; static func parseResponse(_ data: Data) throws -> [String: String] }`
  - `final class FritzTR064Client: PhoneBookService { init(host: String, port: Int = 49443, transport: HTTPTransport) }`

- [ ] **Step 1: Write the failing tests** (`ClientTests.swift`)

```swift
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
            if action.hasSuffix("#GetPhonebookList") { return soapReply("GetPhonebookList", ["NewPhonebookList": "0,1"]) }
            if action.hasSuffix("#GetPhonebook") {
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
            (req.value(forHTTPHeaderField: "SOAPAction") ?? "").hasSuffix("#GetCallList")
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
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/PhoneKit && swift test --filter ClientTests`
Expected: FAIL (compile error: `SOAP` not found).

- [ ] **Step 3: Implement `SOAP.swift`**

```swift
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
```

- [ ] **Step 4: Implement `Transport.swift`**

```swift
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
```

- [ ] **Step 5: Implement `FritzTR064Client.swift`**

```swift
import Foundation
import PhoneCore

public final class FritzTR064Client: PhoneBookService, @unchecked Sendable {
    private let base: URL
    private let transport: HTTPTransport

    public init(host: String, port: Int = 49443, transport: HTTPTransport) {
        self.base = URL(string: "https://\(host):\(port)")!
        self.transport = transport
    }

    private func call(_ action: String, _ args: [(String, String)] = []) async throws -> [String: String] {
        var req = URLRequest(url: base.appendingPathComponent("upnp/control/x_contact"))
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(SOAP.onTelService)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        req.httpBody = SOAP.envelope(service: SOAP.onTelService, action: action, arguments: args)
        return try await SOAP.parseResponse(try await transport.send(req))
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
```

- [ ] **Step 6: Run to verify pass**

Run: `cd Packages/PhoneKit && swift test`
Expected: PASS (all tests so far). If `testLoadContactsMergesPhonebooksWithPrefixedIds` fails because the phonebook-id sniffing in the fake is brittle, simplify the fake to return URLs by call count, but keep the assertions.

- [ ] **Step 7: Add the `fritzdump` dev tool**

`Package.swift`: add `.executableTarget(name: "fritzdump", dependencies: ["FritzTR064", "PhoneCore"])` to `targets`.
`Sources/fritzdump/main.swift`:

```swift
import Foundation
import FritzTR064

final class MemoryPin: PinStore, @unchecked Sendable {
    private var value: String?
    func load() -> String? { value }
    func save(_ fingerprint: String) { value = fingerprint; print("pinned certificate \(fingerprint.prefix(16))…") }
}

let env = ProcessInfo.processInfo.environment
guard let user = env["FRITZ_USER"], let pass = env["FRITZ_PASS"] else {
    print("usage: FRITZ_USER=… FRITZ_PASS=… [FRITZ_HOST=fritz.box] fritzdump"); exit(2)
}
let transport = URLSessionTransport(username: user, password: pass, pins: MemoryPin())
let client = FritzTR064Client(host: env["FRITZ_HOST"] ?? "fritz.box", transport: transport)
do {
    let contacts = try await client.loadContacts()
    print("\(contacts.count) contacts"); contacts.prefix(5).forEach { print(" -", $0.name, $0.numbers.map(\.number)) }
    let calls = try await client.loadCallList()
    print("\(calls.count) calls"); calls.prefix(5).forEach { print(" -", $0.type, $0.remoteNumber, $0.date) }
} catch { print("error:", error); exit(1) }
```

- [ ] **Step 8: Live check against the real Fritz!Box**

Ask the user to run (the `!` prefix runs it in this session): `! cd Packages/PhoneKit && FRITZ_USER=<user> FRITZ_PASS=<password> swift run fritzdump`
Expected: a contact count with a few names and a call count with a few calls. If you get `unauthorized`, the Fritz!Box user lacks the "Phone" / "FRITZ!Box settings" right; if no connection, TR-064 must be enabled under Home Network > Network > Network Settings > Home Network Sharing ("Allow access for applications").

- [ ] **Step 9: Commit**

```bash
git add -A && git commit -m "feat: TR-064 client with digest auth and certificate pinning, fritzdump tool" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Protocols, settings, secrets and `AppCore` (TDD)

**Files:**
- Create: `Sources/PhoneCore/Protocols.swift`, `Sources/PhoneCore/Settings.swift`, `Sources/PhoneCore/Secrets.swift`, `Sources/PhoneCore/ContactCache.swift`, `Sources/PhoneCore/AppCore.swift`
- Test: `Tests/PhoneCoreTests/AppCoreTests.swift`

**Interfaces:**
- Consumes: models and `PhoneBookIndex` (Task 2).
- Produces:
  - `enum RegistrationState: Equatable, Sendable { unregistered, registered, failed(code: Int, reason: String) }`
  - `enum CallState: Equatable, Sendable { calling, ringing, connected, ended(code: Int, reason: String) }`
  - `enum SIPEvent: Equatable, Sendable { registration(RegistrationState); incomingCall(id: Int, remote: String); callState(id: Int, CallState) }`
  - `struct SIPConfig: Equatable, Sendable { host: String; user: String; password: String }`; `enum SIPError: Error, Equatable { authFailed, timeout, failed(String) }`
  - `@MainActor protocol SIPEngine: AnyObject { var events: AsyncStream<SIPEvent> { get }; func register(_: SIPConfig) async throws; func unregister(); func dial(_ number: String) throws -> Int; func answer(_ id: Int); func hangup(_ id: Int); func setMuted(_ muted: Bool); func sendDTMF(_ digits: String, callId: Int) }`
  - `@MainActor protocol VPNControlling: AnyObject { func connect() async throws; func disconnect() async }`
  - `protocol Reachability: Sendable { func isFritzBoxReachable() async -> Bool }`
  - `@MainActor protocol PowerAssertionControlling: AnyObject { func setPreventSleep(_ on: Bool) }`
  - `protocol SecretStore: Sendable { func get(_ key: String) -> String?; func set(_ value: String?, for key: String) throws }`, `enum SecretKey { sipPassword, tr064Password, wireguardConfig }` (static string constants), `KeychainSecretStore`
  - `struct AppSettings: Codable, Equatable, Sendable`, `final class SettingsStore`
  - `protocol ContactCache: Sendable { func load() -> [Contact]; func save(_: [Contact]) }`, `JSONFileContactCache`
  - `@MainActor @Observable final class AppCore` (public API in Step 5)

- [ ] **Step 1: Write `Protocols.swift`**

```swift
import Foundation

public enum RegistrationState: Equatable, Sendable { case unregistered, registered, failed(code: Int, reason: String) }
public enum CallState: Equatable, Sendable { case calling, ringing, connected, ended(code: Int, reason: String) }
public enum SIPEvent: Equatable, Sendable {
    case registration(RegistrationState)
    case incomingCall(id: Int, remote: String)
    case callState(id: Int, CallState)
}
public struct SIPConfig: Equatable, Sendable {
    public var host: String, user: String, password: String
    public init(host: String, user: String, password: String) { self.host = host; self.user = user; self.password = password }
}
public enum SIPError: Error, Equatable { case authFailed, timeout, failed(String) }

@MainActor public protocol SIPEngine: AnyObject {
    var events: AsyncStream<SIPEvent> { get }
    func register(_ config: SIPConfig) async throws
    func unregister()
    func dial(_ number: String) throws -> Int
    func answer(_ callId: Int)
    func hangup(_ callId: Int)
    func setMuted(_ muted: Bool)
    func sendDTMF(_ digits: String, callId: Int)
}
@MainActor public protocol VPNControlling: AnyObject {
    func connect() async throws
    func disconnect() async
}
public protocol Reachability: Sendable { func isFritzBoxReachable() async -> Bool }
@MainActor public protocol PowerAssertionControlling: AnyObject { func setPreventSleep(_ on: Bool) }
```

- [ ] **Step 2: Write `Settings.swift`, `Secrets.swift`, `ContactCache.swift`**

`Settings.swift`:
```swift
import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var fritzHost = "fritz.box"
    public var sipUser = ""
    public var tr064User = ""
    public var countryCode = "49"
    public var areaCode = ""
    public var keepAwakeOnPower = true
    public var launchAtLogin = false
    public init() {}
}

public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "appSettings"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> AppSettings {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
    }
    public func save(_ s: AppSettings) { defaults.set(try? JSONEncoder().encode(s), forKey: key) }
}
```

`Secrets.swift`:
```swift
import Foundation
import Security

public protocol SecretStore: Sendable {
    func get(_ key: String) -> String?
    func set(_ value: String?, for key: String) throws
}
public enum SecretKey {
    public static let sipPassword = "sipPassword"
    public static let tr064Password = "tr064Password"
    public static let wireguardConfig = "wireguardConfig"
}

public struct KeychainSecretStore: SecretStore {
    private let service: String
    public init(service: String = "FritzPhone") { self.service = service }
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
    public func get(_ key: String) -> String? {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    public func set(_ value: String?, for key: String) throws {
        SecItemDelete(query(key) as CFDictionary)
        guard let value else { return }
        var q = query(key); q[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
```

`ContactCache.swift`:
```swift
import Foundation

public protocol ContactCache: Sendable {
    func load() -> [Contact]
    func save(_ contacts: [Contact])
}

public struct JSONFileContactCache: ContactCache {
    private let url: URL
    public init(url: URL) { self.url = url }
    public static func standard() -> JSONFileContactCache {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FritzPhone")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return JSONFileContactCache(url: dir.appendingPathComponent("contacts.json"))
    }
    public func load() -> [Contact] { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Contact].self, from: $0) } ?? [] }
    public func save(_ contacts: [Contact]) { try? JSONEncoder().encode(contacts).write(to: url, options: .atomic) }
}
```

- [ ] **Step 3: Write the failing tests** (`AppCoreTests.swift`)

```swift
import XCTest
@testable import PhoneCore

@MainActor final class FakeSIP: SIPEngine {
    let events: AsyncStream<SIPEvent>
    private let cont: AsyncStream<SIPEvent>.Continuation
    var registerCalls = 0, unregisterCalls = 0
    var registerError: Error?
    var dialed: [String] = [], hangups: [Int] = [], answered: [Int] = []
    init() { let p = AsyncStream<SIPEvent>.makeStream(); events = p.stream; cont = p.continuation }
    func emit(_ e: SIPEvent) { cont.yield(e) }
    func register(_ config: SIPConfig) async throws { registerCalls += 1; if let e = registerError { throw e } }
    func unregister() { unregisterCalls += 1 }
    func dial(_ number: String) throws -> Int { dialed.append(number); return 7 }
    func answer(_ id: Int) { answered.append(id) }
    func hangup(_ id: Int) { hangups.append(id) }
    func setMuted(_ muted: Bool) {}
    func sendDTMF(_ digits: String, callId: Int) {}
}
@MainActor final class FakeVPN: VPNControlling {
    var connectCalls = 0, disconnectCalls = 0
    var error: Error?
    func connect() async throws { connectCalls += 1; if let e = error { throw e } }
    func disconnect() async { disconnectCalls += 1 }
}
final class FakeReach: Reachability, @unchecked Sendable {
    private var results: [Bool]
    private(set) var probes = 0
    init(_ results: [Bool]) { self.results = results }
    func isFritzBoxReachable() async -> Bool { probes += 1; return results.count > 1 ? results.removeFirst() : (results.first ?? false) }
}
@MainActor final class FakePower: PowerAssertionControlling {
    var states: [Bool] = []
    func setPreventSleep(_ on: Bool) { states.append(on) }
}
final class FakeBook: PhoneBookService, @unchecked Sendable {
    var contacts: [Contact] = [Contact(id: "0-1", name: "Erika", numbers: [PhoneNumber(number: "030 1234", type: "home")])]
    var fail = false
    func loadContacts() async throws -> [Contact] { if fail { throw FritzTestError.down }; return contacts }
    func loadCallList() async throws -> [CallRecord] { if fail { throw FritzTestError.down }; return [] }
}
final class FakeCache: ContactCache, @unchecked Sendable {
    var stored: [Contact] = []
    func load() -> [Contact] { stored }
    func save(_ c: [Contact]) { stored = c }
}
enum FritzTestError: Error { case down }
final class DelayLog: @unchecked Sendable { var values: [TimeInterval] = [] }

@MainActor struct Rig {
    let core: AppCore; let sip: FakeSIP; let vpn: FakeVPN; let power: FakePower
    let reach: FakeReach; let book: FakeBook; let cache: FakeCache; let delays: DelayLog
}

@MainActor func makeRig(reach: [Bool], configured: Bool = true) -> Rig {
    let sip = FakeSIP(), vpn = FakeVPN(), power = FakePower(), r = FakeReach(reach), book = FakeBook(), cache = FakeCache(), log = DelayLog()
    let core = AppCore(sip: sip, phoneBook: book, vpn: vpn, reachability: r, power: power, cache: cache,
                       settings: AppSettings(),
                       sipConfig: { configured ? SIPConfig(host: "fritz.box", user: "u", password: "p") : nil },
                       sleep: { log.values.append($0); await Task.yield() })
    return Rig(core: core, sip: sip, vpn: vpn, power: power, reach: r, book: book, cache: cache, delays: log)
}

@MainActor final class AppCoreTests: XCTestCase {
    func testReachableRegistersWithoutVPN() async {
        let r = makeRig(reach: [true])
        await r.core.start()
        XCTAssertEqual(r.core.connection, .ready)
        XCTAssertEqual(r.vpn.connectCalls, 0)
        XCTAssertEqual(r.sip.registerCalls, 1)
        XCTAssertEqual(r.core.contacts.map(\.name), ["Erika"])
    }
    func testUnreachableStartsVPNThenReady() async {
        let r = makeRig(reach: [false, true])
        await r.core.start()
        XCTAssertEqual(r.vpn.connectCalls, 1)
        XCTAssertEqual(r.core.connection, .ready)
    }
    func testVPNFailureGoesOffline() async {
        let r = makeRig(reach: [false]); r.vpn.error = FritzTestError.down
        await r.core.start()
        guard case .offline = r.core.connection else { return XCTFail("expected offline, got \(r.core.connection)") }
        XCTAssertEqual(r.sip.registerCalls, 0)
    }
    func testStillUnreachableAfterVPNGoesOffline() async {
        let r = makeRig(reach: [false, false])
        await r.core.start()
        guard case .offline = r.core.connection else { return XCTFail("expected offline") }
    }
    func testAuthFailureIsTerminalButPhoneBookStillLoads() async {
        let r = makeRig(reach: [true]); r.sip.registerError = SIPError.authFailed
        await r.core.start()
        XCTAssertEqual(r.core.connection, .authFailed)
        XCTAssertEqual(r.core.contacts.count, 1)
        XCTAssertEqual(r.sip.registerCalls, 1)
    }
    func testPhoneBookFailureFallsBackToCacheWithNotice() async {
        let r = makeRig(reach: [true]); r.book.fail = true
        r.cache.stored = [Contact(id: "c", name: "Cached", numbers: [])]
        await r.core.start()
        XCTAssertEqual(r.core.contacts.map(\.name), ["Cached"])
        XCTAssertNotNil(r.core.phoneBookNotice)
        XCTAssertEqual(r.core.connection, .ready)
    }
    func testIncomingCallResolvesNameFromPhoneBook() async {
        let r = makeRig(reach: [true])
        await r.core.start()
        r.core.handle(.incomingCall(id: 3, remote: "+49301234"))
        XCTAssertEqual(r.core.activeCall?.displayName, "Erika")
        XCTAssertEqual(r.core.activeCall?.isIncoming, true)
    }
    func testDialSetsActiveCallAndEndedClearsIt() async {
        let r = makeRig(reach: [true])
        await r.core.start()
        r.core.dial("030 1234")
        XCTAssertEqual(r.sip.dialed, ["030 1234"])
        XCTAssertEqual(r.core.activeCall?.state, .calling)
        r.core.handle(.callState(id: 7, .ended(code: 200, reason: "OK")))
        await r.core.waitForCallCleanup()
        XCTAssertNil(r.core.activeCall)
    }
    func testShutdownStopsVPNOnlyIfStartedByApp() async {
        let a = makeRig(reach: [true]); await a.core.start(); await a.core.shutdown()
        XCTAssertEqual(a.vpn.disconnectCalls, 0)
        let b = makeRig(reach: [false, true]); await b.core.start(); await b.core.shutdown()
        XCTAssertEqual(b.vpn.disconnectCalls, 1)
        XCTAssertEqual(b.sip.unregisterCalls, 1)
    }
    func testKeepAwakeOnlyOnACWhenEnabled() async {
        let r = makeRig(reach: [true])
        r.core.powerSourceChanged(onAC: true);  XCTAssertEqual(r.power.states.last, true)
        r.core.powerSourceChanged(onAC: false); XCTAssertEqual(r.power.states.last, false)
        var s = AppSettings(); s.keepAwakeOnPower = false
        r.core.powerSourceChanged(onAC: true); r.core.updateSettings(s)
        XCTAssertEqual(r.power.states.last, false)
    }
    func testRegistrationLossBacksOffThenRecovers() async {
        let r = makeRig(reach: [true, false, false, true])   // start ok; then 2 failed probes, then ok
        await r.core.start()
        r.core.handle(.registration(.failed(code: 408, reason: "timeout")))
        XCTAssertEqual(r.core.connection, .reconnecting)
        await r.core.waitForReconnect()
        XCTAssertEqual(r.delays.values, [2, 4, 8])
        XCTAssertEqual(r.core.connection, .ready)
        XCTAssertEqual(r.sip.registerCalls, 2)
    }
    func testRegistrationRejectedEventIsAuthFailureWithoutRetry() async {
        let r = makeRig(reach: [true])
        await r.core.start()
        r.core.handle(.registration(.failed(code: 403, reason: "Forbidden")))
        XCTAssertEqual(r.core.connection, .authFailed)
        XCTAssertTrue(r.delays.values.isEmpty)
    }
    func testWakeReprobesAndReRegisters() async {
        let r = makeRig(reach: [true])
        await r.core.start()
        await r.core.handleWake()
        XCTAssertEqual(r.reach.probes, 2)
        XCTAssertEqual(r.sip.registerCalls, 2)
    }
}
```

- [ ] **Step 4: Run to verify failure**

Run: `cd Packages/PhoneKit && swift test --filter AppCoreTests`
Expected: FAIL (compile error: `AppCore` not found).

- [ ] **Step 5: Implement `AppCore.swift`**

```swift
import Foundation
import Observation

@MainActor @Observable
public final class AppCore {
    public enum Connection: Equatable { case starting, connectingVPN, offline(String), authFailed, registering, ready, reconnecting }

    public struct ActiveCall: Equatable {
        public var id: Int
        public var remote: String
        public var displayName: String?
        public var isIncoming: Bool
        public var state: CallState
        public var muted = false
    }

    public private(set) var connection: Connection = .starting
    public private(set) var contacts: [Contact] = []
    public private(set) var history: [CallRecord] = []
    public private(set) var activeCall: ActiveCall?
    public private(set) var phoneBookNotice: String?
    public private(set) var lastError: String?
    public private(set) var settings: AppSettings

    @ObservationIgnored private let sip: SIPEngine
    @ObservationIgnored private let phoneBook: PhoneBookService
    @ObservationIgnored private let vpn: VPNControlling
    @ObservationIgnored private let reachability: Reachability
    @ObservationIgnored private let power: PowerAssertionControlling
    @ObservationIgnored private let cache: ContactCache
    @ObservationIgnored private let sipConfig: () -> SIPConfig?
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async -> Void
    @ObservationIgnored private var index = PhoneBookIndex(contacts: [])
    @ObservationIgnored private var startedVPN = false
    @ObservationIgnored private var onAC = false
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?

    public init(sip: SIPEngine, phoneBook: PhoneBookService, vpn: VPNControlling, reachability: Reachability,
                power: PowerAssertionControlling, cache: ContactCache, settings: AppSettings,
                sipConfig: @escaping () -> SIPConfig?,
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.sip = sip; self.phoneBook = phoneBook; self.vpn = vpn; self.reachability = reachability
        self.power = power; self.cache = cache; self.settings = settings; self.sipConfig = sipConfig; self.sleep = sleep
        rebuildIndex()
    }

    // MARK: Lifecycle

    public func start() async { await connect() }
    public func retry() async { await connect() }
    public func handleWake() async { reconnectTask?.cancel(); reconnectTask = nil; await connect() }

    public func shutdown() async {
        eventTask?.cancel(); reconnectTask?.cancel()
        sip.unregister()
        if startedVPN { await vpn.disconnect(); startedVPN = false }
        power.setPreventSleep(false)
    }

    private func connect() async {
        connection = .starting
        if !(await reachability.isFritzBoxReachable()) {
            connection = .connectingVPN
            do { try await vpn.connect(); startedVPN = true }
            catch { connection = .offline("VPN: \(error.localizedDescription)"); return }
            guard await reachability.isFritzBoxReachable() else { connection = .offline("FRITZ!Box not reachable"); return }
        }
        await refreshPhoneBook()
        guard let cfg = sipConfig() else { connection = .offline("Not configured – open Settings"); return }
        connection = .registering
        do { try await sip.register(cfg) }
        catch SIPError.authFailed { connection = .authFailed; return }
        catch { connection = .offline("SIP: \(error)"); return }
        connection = .ready
        startEventLoop()
    }

    private func startEventLoop() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self, events = sip.events] in
            for await e in events { self?.handle(e) }
        }
    }

    // MARK: Phone book

    public func refreshPhoneBook() async {
        do {
            let c = try await phoneBook.loadContacts()
            contacts = c; cache.save(c); phoneBookNotice = nil
            rebuildIndex()
            history = (try? await phoneBook.loadCallList()) ?? history
        } catch {
            contacts = cache.load(); rebuildIndex()
            phoneBookNotice = "Phone book unavailable (\(error.localizedDescription)); showing saved copy."
        }
    }

    public func refreshHistory() async { if let h = try? await phoneBook.loadCallList() { history = h } }

    private func rebuildIndex() {
        index = PhoneBookIndex(contacts: contacts, countryCode: settings.countryCode,
                               areaCode: settings.areaCode.isEmpty ? nil : settings.areaCode)
    }

    // MARK: Events

    public func handle(_ event: SIPEvent) {
        switch event {
        case .incomingCall(let id, let remote):
            activeCall = ActiveCall(id: id, remote: remote, displayName: index.name(for: remote), isIncoming: true, state: .ringing)
        case .callState(let id, let state):
            guard activeCall?.id == id else { return }
            activeCall?.state = state
            if case .ended = state { scheduleCallCleanup(id) }
        case .registration(.registered):
            connection = .ready
        case .registration(.failed(let code, _)):
            if code == 401 || code == 403 { connection = .authFailed } else { startReconnect() }
        case .registration(.unregistered):
            break
        }
    }

    private func scheduleCallCleanup(_ id: Int) {
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            await self.sleep(2)
            if self.activeCall?.id == id { self.activeCall = nil }
            await self.refreshHistory()
        }
    }
    public func waitForCallCleanup() async { await cleanupTask?.value }

    private func startReconnect() {
        guard reconnectTask == nil else { return }
        connection = .reconnecting
        reconnectTask = Task { [weak self] in
            var delay = 2.0
            while !Task.isCancelled {
                guard let self else { return }
                await self.sleep(delay)
                if Task.isCancelled { break }
                if await self.reachability.isFritzBoxReachable(), let cfg = self.sipConfig() {
                    do { try await self.sip.register(cfg); self.connection = .ready; break }
                    catch SIPError.authFailed { self.connection = .authFailed; break }
                    catch { /* keep retrying */ }
                }
                delay = min(delay * 2, 60)
            }
            self?.reconnectTask = nil
        }
    }
    public func waitForReconnect() async { await reconnectTask?.value }

    // MARK: Calls

    public func dial(_ number: String) {
        guard activeCall == nil, connection == .ready else { return }
        do {
            let id = try sip.dial(number)
            activeCall = ActiveCall(id: id, remote: number, displayName: index.name(for: number), isIncoming: false, state: .calling)
        } catch { lastError = "Call failed: \(error.localizedDescription)" }
    }
    public func answer() { if let c = activeCall { sip.answer(c.id) } }
    public func hangup() { if let c = activeCall { sip.hangup(c.id) } }   // also declines an unanswered incoming call
    public func toggleMute() {
        guard var c = activeCall else { return }
        c.muted.toggle(); activeCall = c; sip.setMuted(c.muted)
    }
    public func sendDTMF(_ digits: String) { if let c = activeCall { sip.sendDTMF(digits, callId: c.id) } }
    public func clearError() { lastError = nil }
    public func reportError(_ message: String) { lastError = message }

    // MARK: Settings and power

    public func updateSettings(_ s: AppSettings) { settings = s; rebuildIndex(); applyPower() }
    public func powerSourceChanged(onAC: Bool) { self.onAC = onAC; applyPower() }
    private func applyPower() { power.setPreventSleep(onAC && settings.keepAwakeOnPower) }
}
```

- [ ] **Step 6: Run to verify pass**

Run: `cd Packages/PhoneKit && swift test`
Expected: PASS (all tests). Fix any failing test by correcting the implementation, not by weakening assertions. Note on `testRegistrationLossBacksOffThenRecovers`: reachability sequence is consumed one probe per call (`true` for start, `false`, `false`, then `true`), giving delays 2, 4, 8.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: AppCore orchestrator, protocols, settings, secrets and contact cache" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 6: App shell UI – contacts, history, settings (first end-to-end proof)

**Files:**
- Create: `App/AppEnvironment.swift`, `App/AppDelegate.swift`, `App/Views/MainView.swift`, `App/Views/ContactsView.swift`, `App/Views/HistoryView.swift`, `App/Views/SettingsView.swift`, `App/Stubs.swift`
- Modify: `App/FritzPhoneApp.swift`

**Interfaces:**
- Consumes: everything in `PhoneCore`, `FritzTR064` (Tasks 2–5).
- Produces: `@MainActor final class AppEnvironment { let core: AppCore; let settingsStore: SettingsStore; let secrets: SecretStore; func applySettings(_:tr064Password:sipPassword:) }`; `Stubs.swift` holds `UnavailableSIPEngine`, `UnavailableVPN`, `NoopPower`, `TCPReachability` that later tasks replace.

- [ ] **Step 1: Write `App/Stubs.swift`** (temporary stand-ins, each replaced in a later task)

```swift
import Foundation
import Network
import PhoneCore

@MainActor final class UnavailableSIPEngine: SIPEngine {   // replaced in Task 8
    let events = AsyncStream<SIPEvent> { _ in }
    func register(_ config: SIPConfig) async throws { throw SIPError.failed("SIP engine not installed yet") }
    func unregister() {}
    func dial(_ number: String) throws -> Int { throw SIPError.failed("SIP engine not installed yet") }
    func answer(_ callId: Int) {}; func hangup(_ callId: Int) {}
    func setMuted(_ muted: Bool) {}; func sendDTMF(_ digits: String, callId: Int) {}
}
@MainActor final class UnavailableVPN: VPNControlling {   // replaced in Task 10
    func connect() async throws { throw SIPError.failed("VPN not installed yet") }
    func disconnect() async {}
}
@MainActor final class NoopPower: PowerAssertionControlling { func setPreventSleep(_ on: Bool) {} }   // replaced in Task 11

/// TCP probe of the TR-064 port (49000, plain HTTP) — no ATS involved.
struct TCPReachability: Reachability {
    let host: @Sendable () -> String
    func isFritzBoxReachable() async -> Bool {
        let conn = NWConnection(host: NWEndpoint.Host(host()), port: 49000, using: .tcp)
        return await withCheckedContinuation { cont in
            let box = OnceBox(cont)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: box.resume(true); conn.cancel()
                case .failed, .cancelled: box.resume(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { box.resume(false); conn.cancel() }
        }
    }
}
private final class OnceBox: @unchecked Sendable {
    private var cont: CheckedContinuation<Bool, Never>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<Bool, Never>) { cont = c }
    func resume(_ v: Bool) { lock.lock(); let c = cont; cont = nil; lock.unlock(); c?.resume(returning: v) }
}
```

- [ ] **Step 2: Write `App/AppEnvironment.swift`**

```swift
import Foundation
import PhoneCore
import FritzTR064

final class UserDefaultsPinStore: PinStore, @unchecked Sendable {
    func load() -> String? { UserDefaults.standard.string(forKey: "tr064CertFingerprint") }
    func save(_ fingerprint: String) { UserDefaults.standard.set(fingerprint, forKey: "tr064CertFingerprint") }
}

/// Late-bound phone book service so changing settings does not require rebuilding AppCore.
final class LivePhoneBook: PhoneBookService, @unchecked Sendable {
    private let make: @Sendable () -> PhoneBookService?
    init(make: @escaping @Sendable () -> PhoneBookService?) { self.make = make }
    func loadContacts() async throws -> [Contact] { try await (make() ?? { throw FritzError.missingField("TR-064 login") }()).loadContacts() }
    func loadCallList() async throws -> [CallRecord] { try await (make() ?? { throw FritzError.missingField("TR-064 login") }()).loadCallList() }
}

@MainActor final class AppEnvironment {
    let settingsStore = SettingsStore()
    let secrets: SecretStore = KeychainSecretStore()
    let core: AppCore

    init() {
        let store = settingsStore, secrets = secrets
        let book = LivePhoneBook {
            let s = store.load()
            guard !s.tr064User.isEmpty, let pw = secrets.get(SecretKey.tr064Password) else { return nil }
            return FritzTR064Client(host: s.fritzHost,
                                    transport: URLSessionTransport(username: s.tr064User, password: pw, pins: UserDefaultsPinStore()))
        }
        core = AppCore(sip: UnavailableSIPEngine(), phoneBook: book, vpn: UnavailableVPN(),
                       reachability: TCPReachability(host: { store.load().fritzHost }),
                       power: NoopPower(), cache: JSONFileContactCache.standard(), settings: store.load(),
                       sipConfig: {
                           let s = store.load()
                           guard !s.sipUser.isEmpty, let pw = secrets.get(SecretKey.sipPassword) else { return nil }
                           return SIPConfig(host: s.fritzHost, user: s.sipUser, password: pw)
                       })
    }

    func applySettings(_ s: AppSettings, tr064Password: String?, sipPassword: String?) async {
        settingsStore.save(s)
        if let p = tr064Password, !p.isEmpty { try? secrets.set(p, for: SecretKey.tr064Password) }
        if let p = sipPassword, !p.isEmpty { try? secrets.set(p, for: SecretKey.sipPassword) }
        core.updateSettings(s)
        await core.retry()
    }
}
```

- [ ] **Step 3: Write `App/AppDelegate.swift` and update `App/FritzPhoneApp.swift`**

`AppDelegate.swift`:
```swift
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let env = AppEnvironment()
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await env.core.start() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        // Best effort: real shutdown (unregister/VPN stop) is awaited in Task 10.
    }
}
```
`FritzPhoneApp.swift`:
```swift
import SwiftUI

@main
struct FritzPhoneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MainView(core: delegate.env.core)
        } label: {
            Image(systemName: delegate.env.core.connection == .ready ? "phone.fill" : "phone")
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView(env: delegate.env) }
    }
}
```

- [ ] **Step 4: Write the views**

`MainView.swift`:
```swift
import SwiftUI
import PhoneCore

struct MainView: View {
    let core: AppCore
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Picker("", selection: $tab) {
                Text("Contacts").tag(0); Text("History").tag(1)
            }.pickerStyle(.segmented).padding(8)
            Group { tab == 0 ? AnyView(ContactsView(core: core)) : AnyView(HistoryView(core: core)) }
            Divider()
            HStack {
                SettingsLink { Text("Settings…") }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }.padding(8)
        }.frame(width: 340, height: 460)
    }

    @ViewBuilder private var statusBar: some View {
        let (text, color): (String, Color) = switch core.connection {
        case .ready: ("Connected", .green)
        case .starting, .registering, .connectingVPN, .reconnecting: ("Connecting…", .orange)
        case .authFailed: ("Login rejected – check Settings", .red)
        case .offline(let r): ("Offline: \(r)", .red)
        }
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).lineLimit(2)
            Spacer()
            if case .offline = core.connection { Button("Retry") { Task { await core.retry() } } }
        }.padding([.horizontal, .top], 8)
        if let n = core.phoneBookNotice { Text(n).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 8) }
    }
}
```

`ContactsView.swift`:
```swift
import SwiftUI
import PhoneCore

struct ContactsView: View {
    let core: AppCore
    @State private var query = ""

    private var filtered: [Contact] {
        query.isEmpty ? core.contacts : core.contacts.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.numbers.contains { $0.number.contains(query) }
        }
    }
    var body: some View {
        VStack {
            TextField("Search or type a number", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 8)
                .onSubmit { if filtered.isEmpty { core.dial(query) } }
            List(filtered) { c in
                VStack(alignment: .leading) {
                    Text(c.name.isEmpty ? (c.numbers.first?.number ?? "—") : c.name).font(.headline)
                    ForEach(c.numbers, id: \.number) { n in
                        Button { core.dial(n.number) } label: {
                            Label("\(n.type) \(n.number)", systemImage: "phone").font(.caption)
                        }.buttonStyle(.link)
                    }
                }
            }
        }
    }
}
```

`HistoryView.swift`:
```swift
import SwiftUI
import PhoneCore

struct HistoryView: View {
    let core: AppCore
    var body: some View {
        List(core.history) { r in
            HStack {
                Image(systemName: icon(r.type)).foregroundStyle(r.type == .missed ? .red : .secondary)
                VStack(alignment: .leading) {
                    Text(r.name ?? r.remoteNumber).font(.headline)
                    Text(r.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { core.dial(r.remoteNumber) } label: { Image(systemName: "phone") }.buttonStyle(.borderless)
            }
        }
        .task { await core.refreshHistory() }
    }
    private func icon(_ t: CallRecordType) -> String {
        switch t {
        case .incoming: "phone.arrow.down.left"; case .missed: "phone.down"
        case .outgoing: "phone.arrow.up.right"; case .rejected: "phone.down.circle"
        }
    }
}
```

`SettingsView.swift`:
```swift
import SwiftUI
import PhoneCore

struct SettingsView: View {
    let env: AppEnvironment
    @State private var s = AppSettings()
    @State private var tr064Password = ""
    @State private var sipPassword = ""
    @State private var wireguard = ""

    var body: some View {
        Form {
            Section("FRITZ!Box") {
                TextField("Address", text: $s.fritzHost)
                TextField("Phone extension user (SIP)", text: $s.sipUser)
                SecureField("SIP password (leave empty to keep)", text: $sipPassword)
                TextField("FRITZ!Box user (TR-064)", text: $s.tr064User)
                SecureField("TR-064 password (leave empty to keep)", text: $tr064Password)
            }
            Section("Numbers") {
                TextField("Country code", text: $s.countryCode)
                TextField("Local area code (e.g. 030)", text: $s.areaCode)
            }
            Section("VPN (WireGuard)") {
                TextEditor(text: $wireguard).font(.system(.caption, design: .monospaced)).frame(height: 90)
                Text("Paste the .conf exported from the FRITZ!Box. It is stored in the Keychain.").font(.caption2)
            }
            Section("Behaviour") {
                Toggle("Keep Mac awake while on power", isOn: $s.keepAwakeOnPower)
            }
            Button("Save") {
                if !wireguard.isEmpty { try? env.secrets.set(wireguard, for: SecretKey.wireguardConfig); wireguard = "" }
                Task { await env.applySettings(s, tr064Password: tr064Password, sipPassword: sipPassword)
                       tr064Password = ""; sipPassword = "" }
            }
        }
        .formStyle(.grouped).frame(width: 440).padding()
        .onAppear { s = env.settingsStore.load() }
    }
}
```

- [ ] **Step 5: Build**

Run: `xcodegen && xcodebuild -scheme FritzPhone -destination 'platform=macOS' build | tail -5`
Expected: `** BUILD SUCCEEDED **`. Fix any compile errors (typical: missing `import`, `switch` expression needs Swift 5.9).

- [ ] **Step 6: Live check**

Run the app from Xcode or `open` the built product. Open Settings from the popover, enter the Fritz!Box address, the TR-064 user and password, click Save. Expected: status shows "Offline: SIP engine not installed yet" (SIP is still a stub) **but** the Contacts tab lists your Fritz!Box phone book and History shows the call list. Quit and relaunch with the Fritz!Box unreachable (e.g. Wi-Fi off): contacts still show from the cache with a notice… (Wi-Fi off gives "Offline: VPN…", so verify the cache by temporarily entering a wrong TR-064 password instead.)

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: menu bar shell with contacts, history and settings" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 7: PJSIP xcframework and bridge smoke test

**Files:**
- Create: `scripts/build-pjsip.sh`, `Packages/PhoneKit/Sources/PJBridge/include/PJBridge.h`, `Packages/PhoneKit/Sources/PJBridge/PJBridge.mm`, `Packages/PhoneKit/Tests/PhoneCoreTests/PJBridgeSmokeTests.swift`
- Modify: `Packages/PhoneKit/Package.swift`

**Interfaces:**
- Produces: `Packages/PhoneKit/Frameworks/PJSIP.xcframework` (static, arm64, headers merged); SPM targets `PJSIP` (binary) and `PJBridge` (ObjC++); `+[PJBridge version]` returning the PJSIP version string.

- [ ] **Step 1: Write `scripts/build-pjsip.sh`**

```bash
#!/bin/bash
# Builds PJSIP (arm64, no video, no TLS) into Packages/PhoneKit/Frameworks/PJSIP.xcframework
set -euo pipefail
VERSION=2.15
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/pjsip"
OUT="$ROOT/Packages/PhoneKit/Frameworks/PJSIP.xcframework"
mkdir -p "$WORK"; cd "$WORK"

if [ ! -d "pjproject-$VERSION" ]; then
  curl -fL -o pj.tgz "https://github.com/pjsip/pjproject/archive/refs/tags/$VERSION.tar.gz"
  tar xzf pj.tgz
fi
cd "pjproject-$VERSION"

cat > pjlib/include/pj/config_site.h <<'EOF'
#define PJ_HAS_IPV6 1
#define PJMEDIA_HAS_VIDEO 0
EOF

export CFLAGS="-arch arm64 -mmacosx-version-min=14.0" LDFLAGS="-arch arm64"
./configure --disable-video --disable-ssl --disable-libyuv --disable-sdl --disable-ffmpeg \
            --disable-openh264 --disable-vpx --disable-opencore-amr --disable-bcg729 --disable-darwin-ssl
make dep && make clean && make -j"$(sysctl -n hw.ncpu)"

# One merged static library
libtool -static -o "$WORK/libpjsip-all.a" $(find . -path '*/lib/*.a' -not -path '*/third_party/*/lib/*.a' -o -path './third_party/lib/*.a')

# One merged header tree
rm -rf "$WORK/headers"; mkdir -p "$WORK/headers"
for d in pjlib pjlib-util pjnath pjmedia pjsip; do cp -R "$d/include/." "$WORK/headers/"; done

rm -rf "$OUT"; mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework -library "$WORK/libpjsip-all.a" -headers "$WORK/headers" -output "$OUT"
echo "Built $OUT"
```

- [ ] **Step 2: Run the build**

Run: `chmod +x scripts/build-pjsip.sh && scripts/build-pjsip.sh 2>&1 | tail -15`
Expected: `Built …/PJSIP.xcframework`. If `configure` rejects a `--disable-*` flag in this PJSIP version, remove that flag (run `./configure --help` in the source dir to see valid ones). If the merged `find` picks up duplicate third-party libs and `libtool` warns about duplicate symbols, restrict the `find` to the `pjlib`, `pjlib-util`, `pjnath`, `pjmedia`, `pjsip` and `third_party` lib directories explicitly. Also bump `VERSION` to the newest tag if 2.15 no longer exists.

- [ ] **Step 3: Add the targets to `Package.swift`**

Add to `targets`:
```swift
.binaryTarget(name: "PJSIP", path: "Frameworks/PJSIP.xcframework"),
.target(name: "PJBridge", dependencies: ["PJSIP"],
        cxxSettings: [.unsafeFlags(["-std=c++17"])],
        linkerSettings: [.linkedLibrary("c++"),
                         .linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox"),
                         .linkedFramework("AudioUnit"), .linkedFramework("AVFoundation"),
                         .linkedFramework("CoreFoundation"), .linkedFramework("Security"),
                         .linkedFramework("SystemConfiguration"), .linkedFramework("Network")]),
```
Add `.library(name: "PJBridge", targets: ["PJBridge"])` to `products`, and in `PhoneCoreTests` dependencies add `"PJBridge"`.

- [ ] **Step 4: Write the minimal bridge (version only)**

`Sources/PJBridge/include/PJBridge.h`:
```objc
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface PJBridge : NSObject
+ (NSString *)version;
@end
NS_ASSUME_NONNULL_END
```
`Sources/PJBridge/PJBridge.mm`:
```objc
#import "PJBridge.h"
#include <pjsua2.hpp>
@implementation PJBridge
+ (NSString *)version { return [NSString stringWithUTF8String:pj_get_version()]; }
@end
```

- [ ] **Step 5: Write the smoke test and run it**

`Tests/PhoneCoreTests/PJBridgeSmokeTests.swift`:
```swift
import XCTest
import PJBridge

final class PJBridgeSmokeTests: XCTestCase {
    func testPJSIPLinks() { XCTAssertTrue(PJBridge.version().hasPrefix("2.")) }
}
```
Run: `cd Packages/PhoneKit && swift test --filter PJBridgeSmokeTests`
Expected: PASS. Linker errors about missing symbols mean a framework is missing from `linkerSettings`; add it.

- [ ] **Step 6: Commit** (the xcframework itself is git-ignored; the script is the source of truth)

```bash
git add -A && git commit -m "build: PJSIP xcframework build script and PJBridge smoke target" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Full PJBridge, `PJSIPEngine` and `siptool` live check

**Files:**
- Modify: `Sources/PJBridge/include/PJBridge.h`, `Sources/PJBridge/PJBridge.mm`, `Package.swift`
- Create: `Sources/SIPEngine/PJSIPEngine.swift`, `Sources/siptool/main.swift`
- Modify: `App/AppEnvironment.swift`, `project.yml` (replace `UnavailableSIPEngine`)

**Interfaces:**
- Consumes: `SIPEngine`, `SIPEvent`, `SIPConfig`, `SIPError` (Task 5).
- Produces: `@MainActor final class PJSIPEngine: NSObject, SIPEngine`; `PJBridge` Objective-C API (below). All PJSIP calls run on the main thread (`threadCnt = 0`, events pumped by a 20 ms timer), so no PJSIP thread registration is needed.

- [ ] **Step 1: Replace `PJBridge.h`**

```objc
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

@protocol PJBridgeDelegate <NSObject>
- (void)registrationChanged:(NSInteger)statusCode reason:(NSString *)reason;
- (void)incomingCall:(NSInteger)callId from:(NSString *)remote;
/// state: "calling" | "ringing" | "connected" | "ended"
- (void)callStateChanged:(NSInteger)callId state:(NSString *)state statusCode:(NSInteger)code reason:(NSString *)reason;
@end

/// Thin ObjC wrapper over pjsua2. Call every method on the main thread; delegate callbacks arrive on the main thread.
@interface PJBridge : NSObject
@property (nonatomic, weak, nullable) id<PJBridgeDelegate> delegate;
+ (NSString *)version;
- (BOOL)startAndReturnError:(NSError **)error;
- (BOOL)registerAccountWithHost:(NSString *)host user:(NSString *)user password:(NSString *)password error:(NSError **)error;
- (void)unregisterAccount;
- (nullable NSNumber *)dial:(NSString *)number error:(NSError **)error;
- (void)answer:(NSInteger)callId;
- (void)hangup:(NSInteger)callId;
- (void)setMuted:(BOOL)muted;
- (void)sendDTMF:(NSString *)digits callId:(NSInteger)callId;
- (void)shutdown;
@end
NS_ASSUME_NONNULL_END
```

- [ ] **Step 2: Replace `PJBridge.mm`**

```objc
#import "PJBridge.h"
#include <pjsua2.hpp>
#include <map>
#include <memory>
#include <string>

using namespace pj;

@interface PJBridge ()
- (void)handleRegCode:(int)code reason:(const std::string &)reason;
- (void)handleIncoming:(int)callId;
- (void)handleCallState:(int)callId;
- (void)applyMuteToCapture;
@end

class BridgeAccount : public Account {
public:
    explicit BridgeAccount(PJBridge *owner) : owner_(owner) {}
    void onRegState(OnRegStateParam &prm) override { [owner_ handleRegCode:prm.code reason:prm.reason]; }
    void onIncomingCall(OnIncomingCallParam &prm) override { [owner_ handleIncoming:prm.callId]; }
private:
    __unsafe_unretained PJBridge *owner_;
};

class BridgeCall : public Call {
public:
    BridgeCall(Account &acc, int callId, PJBridge *owner) : Call(acc, callId), owner_(owner) {}
    void onCallState(OnCallStateParam &) override { [owner_ handleCallState:getId()]; }
    void onCallMediaState(OnCallMediaStateParam &) override {
        CallInfo ci = getInfo();
        for (unsigned i = 0; i < ci.media.size(); i++) {
            if (ci.media[i].type == PJMEDIA_TYPE_AUDIO && ci.media[i].status == PJSUA_CALL_MEDIA_ACTIVE) {
                AudioMedia *aud = static_cast<AudioMedia *>(getMedia(i));
                AudDevManager &mgr = Endpoint::instance().audDevManager();
                aud->startTransmit(mgr.getPlaybackDevMedia());
                mgr.getCaptureDevMedia().startTransmit(*aud);
            }
        }
        [owner_ applyMuteToCapture];
    }
private:
    __unsafe_unretained PJBridge *owner_;
};

@implementation PJBridge {
    std::unique_ptr<Endpoint> _ep;
    std::unique_ptr<BridgeAccount> _acc;
    std::map<int, std::unique_ptr<BridgeCall>> _calls;
    NSTimer *_timer;
    std::string _host;
    BOOL _muted;
}

+ (NSString *)version { return [NSString stringWithUTF8String:pj_get_version()]; }

static NSError *PJError(const std::string &msg) {
    return [NSError errorWithDomain:@"PJBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: @(msg.c_str())}];
}

- (BOOL)startAndReturnError:(NSError **)error {
    if (_ep) return YES;
    try {
        _ep.reset(new Endpoint);
        _ep->libCreate();
        EpConfig cfg;
        cfg.uaConfig.threadCnt = 0;              // we pump events from the main thread
        cfg.uaConfig.mainThreadOnly = true;
        cfg.uaConfig.userAgent = "FritzPhone";
        cfg.logConfig.level = 3; cfg.logConfig.consoleLevel = 3;
        cfg.medConfig.threadCnt = 1;
        cfg.medConfig.ecTaps = 256;              // echo cancellation
        _ep->libInit(cfg);
        TransportConfig tcfg; tcfg.port = 0;
        _ep->transportCreate(PJSIP_TRANSPORT_UDP, tcfg);
        _ep->libStart();
        // Codecs: G.722, PCMA, PCMU only
        for (const CodecInfo &ci : _ep->codecEnum2()) {
            pj_uint8_t prio = 0;
            if (ci.codecId == "G722/16000/1") prio = 255;
            else if (ci.codecId == "PCMA/8000/1") prio = 254;
            else if (ci.codecId == "PCMU/8000/1") prio = 253;
            _ep->codecSetPriority(ci.codecId, prio);
        }
        _timer = [NSTimer scheduledTimerWithTimeInterval:0.02 repeats:YES block:^(NSTimer *) {
            if (self->_ep) { try { self->_ep->libHandleEvents(0); } catch (...) {} }
        }];
        [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
        return YES;
    } catch (Error &e) {
        if (error) *error = PJError(e.info());
        _ep.reset();
        return NO;
    }
}

- (BOOL)registerAccountWithHost:(NSString *)host user:(NSString *)user password:(NSString *)password error:(NSError **)error {
    try {
        _acc.reset();
        _host = host.UTF8String;
        AccountConfig ac;
        ac.idUri = "sip:" + std::string(user.UTF8String) + "@" + _host;
        ac.regConfig.registrarUri = "sip:" + _host;
        ac.regConfig.timeoutSec = 300;
        ac.sipConfig.authCreds.push_back(AuthCredInfo("digest", "*", user.UTF8String, 0, password.UTF8String));
        _acc.reset(new BridgeAccount(self));
        _acc->create(ac);
        return YES;
    } catch (Error &e) {
        if (error) *error = PJError(e.info());
        return NO;
    }
}

- (void)unregisterAccount {
    try { if (_acc) _acc->setRegistration(false); } catch (...) {}
}

- (nullable NSNumber *)dial:(NSString *)number error:(NSError **)error {
    if (!_acc) { if (error) *error = PJError("Not registered"); return nil; }
    NSString *clean = [[number stringByReplacingOccurrencesOfString:@" " withString:@""]
                       stringByReplacingOccurrencesOfString:@"#" withString:@"%23"];
    try {
        std::unique_ptr<BridgeCall> call(new BridgeCall(*_acc, PJSUA_INVALID_ID, self));
        CallOpParam prm(true);
        call->makeCall("sip:" + std::string(clean.UTF8String) + "@" + _host, prm);
        int id = call->getId();
        _calls[id] = std::move(call);
        return @(id);
    } catch (Error &e) {
        if (error) *error = PJError(e.info());
        return nil;
    }
}

- (void)handleIncoming:(int)callId {
    std::unique_ptr<BridgeCall> call(new BridgeCall(*_acc, callId, self));
    NSString *remote = @(call->getInfo().remoteUri.c_str());
    try { CallOpParam ringing; ringing.statusCode = PJSIP_SC_RINGING; call->answer(ringing); } catch (...) {}
    _calls[callId] = std::move(call);
    [self.delegate incomingCall:callId from:remote];
}

- (void)handleCallState:(int)callId {
    auto it = _calls.find(callId);
    if (it == _calls.end()) return;
    CallInfo ci = it->second->getInfo();
    NSString *state = nil;
    switch (ci.state) {
        case PJSIP_INV_STATE_CALLING: state = @"calling"; break;
        case PJSIP_INV_STATE_EARLY: state = @"ringing"; break;
        case PJSIP_INV_STATE_CONFIRMED: state = @"connected"; break;
        case PJSIP_INV_STATE_DISCONNECTED: state = @"ended"; break;
        default: break;
    }
    if (!state) return;
    [self.delegate callStateChanged:callId state:state statusCode:ci.lastStatusCode reason:@(ci.lastReason.c_str())];
    if (ci.state == PJSIP_INV_STATE_DISCONNECTED) {
        dispatch_async(dispatch_get_main_queue(), ^{ self->_calls.erase(callId); });   // never delete a Call inside its own callback
    }
}

- (void)handleRegCode:(int)code reason:(const std::string &)reason {
    [self.delegate registrationChanged:code reason:@(reason.c_str())];
}

- (void)answer:(NSInteger)callId {
    auto it = _calls.find((int)callId); if (it == _calls.end()) return;
    try { CallOpParam prm; prm.statusCode = PJSIP_SC_OK; it->second->answer(prm); } catch (...) {}
}

- (void)hangup:(NSInteger)callId {
    auto it = _calls.find((int)callId); if (it == _calls.end()) return;
    try { CallOpParam prm; prm.statusCode = PJSIP_SC_DECLINE; it->second->hangup(prm); } catch (...) {}
}

- (void)setMuted:(BOOL)muted { _muted = muted; [self applyMuteToCapture]; }

- (void)applyMuteToCapture {
    try { Endpoint::instance().audDevManager().getCaptureDevMedia().adjustTxLevel(_muted ? 0.0f : 1.0f); } catch (...) {}
}

- (void)sendDTMF:(NSString *)digits callId:(NSInteger)callId {
    auto it = _calls.find((int)callId); if (it == _calls.end()) return;
    try { it->second->dialDtmf(digits.UTF8String); } catch (...) {}
}

- (void)shutdown {
    [_timer invalidate]; _timer = nil;
    _calls.clear(); _acc.reset();
    if (_ep) { try { _ep->libDestroy(); } catch (...) {} _ep.reset(); }
}
@end
```
Note: if `cfg.uaConfig.mainThreadOnly` does not exist in the built PJSIP version, delete that line (it is only a safety flag).

- [ ] **Step 3: Write `Sources/SIPEngine/PJSIPEngine.swift`**

```swift
import Foundation
import PhoneCore
import PJBridge

@MainActor
public final class PJSIPEngine: NSObject, SIPEngine, PJBridgeDelegate {
    public let events: AsyncStream<SIPEvent>
    private let continuation: AsyncStream<SIPEvent>.Continuation
    private let bridge = PJBridge()
    private var started = false
    private var pending: CheckedContinuation<Void, Error>?

    public override init() {
        let p = AsyncStream<SIPEvent>.makeStream()
        events = p.stream; continuation = p.continuation
        super.init()
        bridge.delegate = self
    }

    public func register(_ config: SIPConfig) async throws {
        if !started { try bridge.start(); started = true }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pending = c
            do { try bridge.registerAccount(withHost: config.host, user: config.user, password: config.password) }
            catch { resolve(.failure(SIPError.failed(error.localizedDescription))) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.resolve(.failure(SIPError.timeout))
            }
        }
    }

    private func resolve(_ result: Result<Void, Error>) {
        guard let c = pending else { return }
        pending = nil
        c.resume(with: result)
    }

    public func unregister() { bridge.unregisterAccount(); continuation.yield(.registration(.unregistered)) }

    public func dial(_ number: String) throws -> Int { try bridge.dial(number).intValue }
    public func answer(_ callId: Int) { bridge.answer(callId) }
    public func hangup(_ callId: Int) { bridge.hangup(callId) }
    public func setMuted(_ muted: Bool) { bridge.setMuted(muted) }
    public func sendDTMF(_ digits: String, callId: Int) { bridge.sendDTMF(digits, callId: callId) }

    // MARK: PJBridgeDelegate (always invoked on the main thread)

    public nonisolated func registrationChanged(_ statusCode: Int, reason: String) {
        MainActor.assumeIsolated {
            if pending != nil {
                switch statusCode {
                case 200..<300: resolve(.success(()))
                case 401, 403: resolve(.failure(SIPError.authFailed))
                case 300...: resolve(.failure(SIPError.failed("\(statusCode) \(reason)")))
                default: break
                }
            } else if statusCode >= 200 {
                continuation.yield(.registration(statusCode < 300 ? .registered : .failed(code: statusCode, reason: reason)))
            }
        }
    }
    public nonisolated func incomingCall(_ callId: Int, from remote: String) {
        MainActor.assumeIsolated { continuation.yield(.incomingCall(id: callId, remote: Self.userPart(of: remote))) }
    }
    public nonisolated func callStateChanged(_ callId: Int, state: String, statusCode code: Int, reason: String) {
        MainActor.assumeIsolated {
            let s: CallState
            switch state {
            case "calling": s = .calling
            case "ringing": s = .ringing
            case "connected": s = .connected
            default: s = .ended(code: code, reason: reason)
            }
            continuation.yield(.callState(id: callId, s))
        }
    }

    /// "\"Name\" <sip:0301234@fritz.box>" -> "0301234"
    nonisolated static func userPart(of uri: String) -> String {
        guard let r = uri.range(of: "sip:") else { return uri }
        let rest = uri[r.upperBound...]
        return String(rest.prefix { $0 != "@" && $0 != ">" && $0 != ";" })
    }
}
```

- [ ] **Step 4: Package targets, `siptool`, and app wiring**

`Package.swift`: add `.target(name: "SIPEngine", dependencies: ["PhoneCore", "PJBridge"])`, `.executableTarget(name: "siptool", dependencies: ["SIPEngine", "PhoneCore"])`, and `.library(name: "SIPEngine", targets: ["SIPEngine"])`.
`project.yml`: add `- package: PhoneKit` / `product: SIPEngine` to the app's dependencies.
`App/AppEnvironment.swift`: `import SIPEngine` and replace `UnavailableSIPEngine()` with `PJSIPEngine()`; delete `UnavailableSIPEngine` from `Stubs.swift`.

`Sources/siptool/main.swift`:
```swift
import Foundation
import PhoneCore
import SIPEngine

// usage: SIP_HOST=fritz.box SIP_USER=… SIP_PASS=… siptool [number-to-dial]
let env = ProcessInfo.processInfo.environment
guard let user = env["SIP_USER"], let pass = env["SIP_PASS"] else { print("set SIP_USER and SIP_PASS"); exit(2) }

Task { @MainActor in
    let engine = PJSIPEngine()
    Task { for await e in engine.events { print("event:", e) } }
    do {
        try await engine.register(SIPConfig(host: env["SIP_HOST"] ?? "fritz.box", user: user, password: pass))
        print("registered")
        if CommandLine.arguments.count > 1 {
            let id = try engine.dial(CommandLine.arguments[1]); print("dialing, call id", id)
            try? await Task.sleep(for: .seconds(20)); engine.hangup(id)
        } else {
            print("waiting 60 s for an incoming call…"); try? await Task.sleep(for: .seconds(60))
        }
        engine.unregister(); exit(0)
    } catch { print("error:", error); exit(1) }
}
RunLoop.main.run()
```

- [ ] **Step 5: Build and run tests**

Run: `cd Packages/PhoneKit && swift build && swift test 2>&1 | tail -5`
Expected: build OK, all tests PASS.

- [ ] **Step 6: Live check (needs the user)**

Ask the user to create an "IP telephone" in the Fritz!Box (Telephony > Telephony Devices > Set up new device > Telephone (with and without answering machine) > "LAN/WLAN (IP telephone)"), note the user name and password, then run `! cd Packages/PhoneKit && SIP_USER=<user> SIP_PASS=<pw> swift run siptool`. Expected: `registered`. Then call the Fritz!Box number from another phone during the 60 s: expect `event: incomingCall(...)` followed by `callState` events. Then `swift run siptool <number>`: the target phone rings, `ringing`/`connected` appear, audio works both ways (macOS asks for microphone permission on first use). Report anything else (`authFailed`, `timeout`) to the user rather than guessing.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: PJSIP-backed SIPEngine with ObjC++ bridge and siptool" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Call UI, notifications, mute and DTMF

**Files:**
- Create: `App/Views/InCallView.swift`, `App/Views/DialPadView.swift`, `App/CallWindowController.swift`, `App/NotificationService.swift`, `App/Observe.swift`
- Modify: `App/AppDelegate.swift`, `App/Views/MainView.swift`

**Interfaces:**
- Consumes: `AppCore.activeCall`, `answer()`, `hangup()`, `toggleMute()`, `sendDTMF(_:)`, `dial(_:)`, `reportError(_:)` (Task 5).
- Produces: a floating call panel that appears for any active call; a UserNotification with Answer/Decline actions for incoming calls; a "Keypad" tab in the popover.

- [ ] **Step 1: Write `App/Observe.swift`**

```swift
import Observation

/// Re-runs `apply` whenever any @Observable property read inside it changes.
@MainActor func observe(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking { apply() } onChange: {
        Task { @MainActor in observe(apply) }
    }
}
```

- [ ] **Step 2: Write `InCallView.swift`**

```swift
import SwiftUI
import PhoneCore

struct InCallView: View {
    let core: AppCore
    @State private var showKeypad = false
    @State private var connectedAt: Date?

    var body: some View {
        if let call = core.activeCall {
            VStack(spacing: 12) {
                Text(call.displayName ?? call.remote).font(.title2).lineLimit(1)
                if call.displayName != nil { Text(call.remote).font(.caption).foregroundStyle(.secondary) }
                statusText(call)
                if call.state == .connected {
                    HStack(spacing: 16) {
                        Button { core.toggleMute() } label: {
                            Label(call.muted ? "Unmute" : "Mute", systemImage: call.muted ? "mic.slash.fill" : "mic.fill")
                        }
                        Button { showKeypad.toggle() } label: { Label("Keypad", systemImage: "circle.grid.3x3.fill") }
                    }
                    if showKeypad { DialPadView { core.sendDTMF($0) } }
                }
                HStack(spacing: 16) {
                    if call.isIncoming && call.state == .ringing {
                        Button("Answer") { Task { await answer() } }.tint(.green).keyboardShortcut(.defaultAction)
                        Button("Decline") { core.hangup() }.tint(.red)
                    } else if case .ended = call.state {
                        EmptyView()
                    } else {
                        Button("Hang up") { core.hangup() }.tint(.red)
                    }
                }.buttonStyle(.borderedProminent)
            }
            .padding(20).frame(width: 300)
            .onChange(of: call.state) { _, s in if s == .connected { connectedAt = Date() } }
        }
    }

    @ViewBuilder private func statusText(_ call: AppCore.ActiveCall) -> some View {
        switch call.state {
        case .calling: Text("Calling…")
        case .ringing: Text(call.isIncoming ? "Incoming call" : "Ringing…")
        case .connected:
            if let t = connectedAt { Text(t, style: .timer).monospacedDigit() } else { Text("Connected") }
        case .ended(let code, let reason): Text(code == 200 || code == 487 ? "Call ended" : "Call ended: \(reason)")
        }
    }

    private func answer() async {
        if await Microphone.ensureAccess() { core.answer() }
        else { core.reportError("Microphone access denied"); core.hangup() }
    }
}
```

- [ ] **Step 3: Write `DialPadView.swift`, with the microphone helper**

```swift
import SwiftUI
import AVFoundation
import AppKit

enum Microphone {
    static func ensureAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            return false
        }
    }
}

struct DialPadView: View {
    let onKey: (String) -> Void
    private let keys = [["1","2","3"],["4","5","6"],["7","8","9"],["*","0","#"]]
    var body: some View {
        VStack(spacing: 6) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { k in
                        Button(k) { onKey(k) }.frame(width: 56, height: 36).font(.title3)
                    }
                }
            }
        }
    }
}

/// Dial-tab content: number display plus keypad plus call button.
struct DialTab: View {
    let core: AppCore
    @State private var number = ""
    var body: some View {
        VStack(spacing: 10) {
            TextField("Number", text: $number).textFieldStyle(.roundedBorder).multilineTextAlignment(.center).font(.title3)
            DialPadView { number += $0 }
            HStack {
                Button { if !number.isEmpty { number.removeLast() } } label: { Image(systemName: "delete.left") }
                Button("Call") {
                    Task {
                        if await Microphone.ensureAccess() { core.dial(number) }
                        else { core.reportError("Microphone access denied – allow it in System Settings") }
                    }
                }.buttonStyle(.borderedProminent).tint(.green).disabled(number.isEmpty || core.connection != .ready)
            }
        }.padding()
    }
}
```
In `ContactsView` and `HistoryView`, wrap each `core.dial(...)` in `Task { if await Microphone.ensureAccess() { core.dial(...) } else { core.reportError("Microphone access denied – allow it in System Settings") } }`. In `MainView` add a third tab `Text("Keypad").tag(2)` showing `DialTab(core: core)`, and show `core.lastError` as a red caption with a dismiss button above the tab picker.

- [ ] **Step 4: Write `CallWindowController.swift`**

```swift
import AppKit
import SwiftUI
import PhoneCore

@MainActor final class CallWindowController {
    private var panel: NSPanel?
    private let core: AppCore
    init(core: AppCore) { self.core = core }

    func update() {
        if core.activeCall != nil {
            if panel == nil {
                let p = NSPanel(contentViewController: NSHostingController(rootView: InCallView(core: core)))
                p.styleMask = [.titled, .nonactivatingPanel, .fullSizeContentView]
                p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true
                p.level = .floating; p.isReleasedWhenClosed = false
                p.center()
                panel = p
            }
            panel?.orderFrontRegardless()
        } else {
            panel?.close(); panel = nil
        }
    }
}
```

- [ ] **Step 5: Write `NotificationService.swift`**

```swift
import UserNotifications
import PhoneCore

@MainActor final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let core: AppCore
    private var notifiedCallId: Int?
    init(core: AppCore) { self.core = core; super.init() }

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: "INCOMING", actions: [
            UNNotificationAction(identifier: "ANSWER", title: "Answer", options: [.foreground]),
            UNNotificationAction(identifier: "DECLINE", title: "Decline", options: [.destructive]),
        ], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Call from the observation loop whenever `core.activeCall` changes.
    func update() {
        let center = UNUserNotificationCenter.current()
        guard let call = core.activeCall, call.isIncoming, call.state == .ringing else {
            if let id = notifiedCallId { center.removeDeliveredNotifications(withIdentifiers: ["call-\(id)"]); notifiedCallId = nil }
            return
        }
        guard notifiedCallId != call.id else { return }
        notifiedCallId = call.id
        let c = UNMutableNotificationContent()
        c.title = call.displayName ?? call.remote
        c.body = "Incoming call"; c.categoryIdentifier = "INCOMING"; c.sound = .defaultCritical
        center.add(UNNotificationRequest(identifier: "call-\(call.id)", content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let action = response.actionIdentifier
        Task { @MainActor in
            if action == "ANSWER", await Microphone.ensureAccess() { core.answer() }
            else if action == "DECLINE" { core.hangup() }
            done()
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
```

- [ ] **Step 6: Wire into `AppDelegate`**

```swift
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let env = AppEnvironment()
    private lazy var callWindow = CallWindowController(core: env.core)
    private lazy var notifications = NotificationService(core: env.core)

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifications.setUp()
        observe { [self] in
            _ = env.core.activeCall          // establishes the observation
            callWindow.update(); notifications.update()
        }
        Task { await env.core.start() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await env.core.shutdown(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
```

- [ ] **Step 7: Build and live check**

Run: `xcodegen && xcodebuild -scheme FritzPhone -destination 'platform=macOS' build | tail -5`
Expected: `** BUILD SUCCEEDED **`. Then with the user at the Mac: (a) status shows "Connected"; (b) call from the Keypad tab → the other phone rings, the call panel shows "Ringing…", then a running timer; mute and DTMF (press a key during a call to an IVR/answering machine) work; hang up closes the panel after ~2 s; (c) call the Fritz!Box number from a mobile → a notification with the caller's phonebook name and Answer/Decline plus the floating panel appear; Answer connects audio, Decline hangs up; (d) the History tab shows the new entries. Record any failures for the user.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat: call UI, incoming-call notifications, mute and DTMF" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 10: WireGuard VPN (`VPNManager` and `PacketTunnel` extension)

**Files:**
- Create: `Packages/PhoneKit/Sources/VPN/VPNManager.swift`, `PacketTunnel/PacketTunnelProvider.swift`
- Modify: `Packages/PhoneKit/Package.swift`, `project.yml`, `App/AppEnvironment.swift`, `App/Stubs.swift`

**Interfaces:**
- Consumes: `VPNControlling`, `SecretStore`, `SecretKey.wireguardConfig` (Task 5).
- Produces: `@MainActor final class VPNManager: VPNControlling { init(secrets: SecretStore, extensionBundleId: String, accessGroup: String) }`. The WireGuard config (wg-quick text) is kept in a Keychain item in a shared access group; the tunnel's `passwordReference` points to it, so the private key never lives in VPN preferences.

- [ ] **Step 1: Write `VPNManager.swift`**

```swift
import Foundation
import NetworkExtension
import Security
import PhoneCore

public enum VPNError: Error, LocalizedError {
    case notConfigured, keychain(OSStatus), timeout, stopped
    public var errorDescription: String? {
        switch self {
        case .notConfigured: "No WireGuard configuration in Settings"
        case .keychain(let s): "Keychain error \(s)"
        case .timeout: "VPN did not connect in time"
        case .stopped: "VPN stopped unexpectedly"
        }
    }
}

@MainActor
public final class VPNManager: VPNControlling {
    private let secrets: SecretStore
    private let extensionBundleId: String
    private let accessGroup: String
    private var manager: NETunnelProviderManager?

    public init(secrets: SecretStore, extensionBundleId: String, accessGroup: String) {
        self.secrets = secrets; self.extensionBundleId = extensionBundleId; self.accessGroup = accessGroup
    }

    public func connect() async throws {
        guard let config = secrets.get(SecretKey.wireguardConfig) else { throw VPNError.notConfigured }
        let ref = try storeSharedConfig(config)
        let m = try await NETunnelProviderManager.loadAllFromPreferences().first ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = extensionBundleId
        proto.serverAddress = "FRITZ!Box"
        proto.passwordReference = ref
        m.protocolConfiguration = proto
        m.localizedDescription = "FRITZ!Box"
        m.isEnabled = true
        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        manager = m
        try m.connection.startVPNTunnel()
        for _ in 0..<80 {                                   // up to 20 s
            switch m.connection.status {
            case .connected: return
            case .disconnected, .invalid: throw VPNError.stopped
            default: try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw VPNError.timeout
    }

    public func disconnect() async { manager?.connection.stopVPNTunnel() }

    /// Stores the wg-quick config in the shared keychain group and returns a persistent reference the extension can resolve.
    private func storeSharedConfig(_ config: String) throws -> Data {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "FritzPhone.WireGuard",
            kSecAttrAccount as String: "config",
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(config.utf8)
        add[kSecReturnPersistentRef as String] = true
        var out: AnyObject?
        let status = SecItemAdd(add as CFDictionary, &out)
        guard status == errSecSuccess, let ref = out as? Data else { throw VPNError.keychain(status) }
        return ref
    }
}
```
`Package.swift`: add `.target(name: "VPN", dependencies: ["PhoneCore"])` and `.library(name: "VPN", targets: ["VPN"])`.

- [ ] **Step 2: Write `PacketTunnel/PacketTunnelProvider.swift`**

```swift
import NetworkExtension
import Security
import WireGuardKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var adapter = WireGuardAdapter(with: self) { level, message in NSLog("WireGuard[%d]: %@", level.rawValue, message) }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let ref = proto.passwordReference,
              let text = Self.readConfig(persistentRef: ref),
              let config = try? TunnelConfiguration(fromWgQuickConfig: text, called: "FRITZ!Box") else {
            completionHandler(NSError(domain: "PacketTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing or invalid WireGuard config"]))
            return
        }
        adapter.start(tunnelConfiguration: config) { error in completionHandler(error) }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        adapter.stop { _ in completionHandler() }
    }

    private static func readConfig(persistentRef: Data) -> String? {
        let q: [String: Any] = [kSecValuePersistentRef as String: persistentRef, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
```

- [ ] **Step 3: Update `project.yml`**

Add under `packages`:
```yaml
  WireGuardApple: { url: "https://git.zx2c4.com/wireguard-apple", branch: master }
```
Add to the app target: dependency `- package: PhoneKit` / `product: VPN`, dependency `- target: PacketTunnel`, and entitlements properties:
```yaml
        com.apple.developer.networking.networkextension: [packet-tunnel-provider]
        com.apple.security.application-groups: [TEAMID.group.com.example.fritzphone]
        keychain-access-groups: ["$(AppIdentifierPrefix)com.example.fritzphone"]
```
Add a new target:
```yaml
  PacketTunnel:
    type: app-extension
    platform: macOS
    sources: [PacketTunnel]
    dependencies:
      - package: WireGuardApple
        product: WireGuardKit
    info:
      path: PacketTunnel/Info.plist
      properties:
        NSExtension:
          NSExtensionPointIdentifier: com.apple.networkextension.packet-tunnel
          NSExtensionPrincipalClass: "$(PRODUCT_MODULE_NAME).PacketTunnelProvider"
    entitlements:
      path: PacketTunnel/PacketTunnel.entitlements
      properties:
        com.apple.developer.networking.networkextension: [packet-tunnel-provider]
        com.apple.security.app-sandbox: true
        com.apple.security.network.client: true
        com.apple.security.network.server: true
        keychain-access-groups: ["$(AppIdentifierPrefix)com.example.fritzphone"]
```
(Use the real bundle prefix and Team ID from Task 1.) In the Apple Developer portal the user must enable the Network Extensions capability on both App IDs (automatic signing normally does this). WireGuardKit builds its Go bridge with `go`, which was installed in Task 1.

- [ ] **Step 4: Replace the VPN stub**

`App/AppEnvironment.swift`: `import VPN`, replace `UnavailableVPN()` with
`VPNManager(secrets: secrets, extensionBundleId: "com.example.fritzphone.PacketTunnel", accessGroup: "TEAMID.com.example.fritzphone")`.
Delete `UnavailableVPN` from `Stubs.swift`.

- [ ] **Step 5: Build**

Run: `xcodegen && xcodebuild -scheme FritzPhone -destination 'platform=macOS' build | tail -8`
Expected: `** BUILD SUCCEEDED **` (first build is slow because of the Go bridge). Fix signing errors by checking Team ID and that the Network Extension capability is enabled.

- [ ] **Step 6: Live check (needs the user)**

In the Fritz!Box: Home Network > Network > Network Settings > Home Network Sharing > add a WireGuard connection for this Mac and export the `.conf`. Paste it into the app's Settings (VPN field) and Save. Then leave the home network (use a phone hotspot) and relaunch the app. Expected: macOS asks once to allow the VPN configuration; the status goes "Connecting…" then "Connected"; contacts and calls work through the tunnel. Quit the app: the tunnel stops. At home (Fritz!Box reachable) the app must not start the VPN.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: automatic WireGuard VPN via packet-tunnel extension" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Power, sleep/wake and network-change adapters

**Files:**
- Create: `Packages/PhoneKit/Sources/System/PowerAssertion.swift`, `Packages/PhoneKit/Sources/System/SystemMonitors.swift`
- Modify: `Packages/PhoneKit/Package.swift`, `project.yml`, `App/AppEnvironment.swift`, `App/AppDelegate.swift`, `App/Stubs.swift`

**Interfaces:**
- Consumes: `PowerAssertionControlling`, `AppCore.powerSourceChanged(onAC:)`, `AppCore.handleWake()` (Task 5; already unit-tested).
- Produces: `IOKitPowerAssertion: PowerAssertionControlling`, `SystemMonitors` (starts power-source, wake and network-path observation).

- [ ] **Step 1: Write `PowerAssertion.swift`**

```swift
import Foundation
import IOKit.pwr_mgt
import PhoneCore

@MainActor
public final class IOKitPowerAssertion: PowerAssertionControlling {
    private var assertionID: IOPMAssertionID = 0
    private var held = false
    public init() {}

    public func setPreventSleep(_ on: Bool) {
        if on, !held {
            held = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "FRITZ!Box phone must stay reachable" as CFString,
                                               &assertionID) == kIOReturnSuccess
        } else if !on, held {
            IOPMAssertionRelease(assertionID); held = false
        }
    }
}
```

- [ ] **Step 2: Write `SystemMonitors.swift`**

```swift
import AppKit
import IOKit.ps
import Network
import PhoneCore

@MainActor
public final class SystemMonitors {
    private let core: AppCore
    private var pathMonitor: NWPathMonitor?
    private var powerSource: CFRunLoopSource?
    private var lastPathSignature = ""
    private var debounce: Task<Void, Never>?

    public init(core: AppCore) { self.core = core }

    public func start() {
        // Power source (AC vs battery)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<SystemMonitors>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in me.reportPower() }
        }, ctx)?.takeRetainedValue() {
            powerSource = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        reportPower()

        // Wake from sleep
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [core] _ in
            Task { @MainActor in await core.handleWake() }
        }

        // Network path changes (Wi-Fi switch, VPN up/down) -> re-register, debounced
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let sig = path.availableInterfaces.map(\.name).joined(separator: ",") + (path.status == .satisfied ? "+" : "-")
            Task { @MainActor in self?.pathChanged(sig) }
        }
        monitor.start(queue: .global())
        pathMonitor = monitor
    }

    private func reportPower() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        core.powerSourceChanged(onAC: type == kIOPSACPowerValue)
    }

    private func pathChanged(_ signature: String) {
        guard signature != lastPathSignature else { return }
        let first = lastPathSignature.isEmpty
        lastPathSignature = signature
        guard !first else { return }              // ignore the initial callback
        debounce?.cancel()
        debounce = Task { [core] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled, core.connection != .connectingVPN { await core.handleWake() }
        }
    }
}
```
`Package.swift`: add `.target(name: "System", dependencies: ["PhoneCore"])` and `.library(name: "System", targets: ["System"])`; rename the target and product to `SystemAdapters` if the name `System` clashes with the Swift `System` module (it does in practice — use `SystemAdapters` from the start, with directory `Sources/SystemAdapters`). In `project.yml` add the product to the app dependencies.

- [ ] **Step 3: Wire up**

`App/AppEnvironment.swift`: `import SystemAdapters`, replace `NoopPower()` with `IOKitPowerAssertion()`; delete `NoopPower` from `Stubs.swift`; add `lazy var monitors = SystemMonitors(core: core)`.
`App/AppDelegate.swift`: in `applicationDidFinishLaunching` call `env.monitors.start()` before `env.core.start()`.

- [ ] **Step 4: Build and live check**

Run: `xcodegen && xcodebuild -scheme FritzPhone -destination 'platform=macOS' build | tail -5`
Expected: `** BUILD SUCCEEDED **`. Verify manually:
1. On AC with the app running, `pmset -g assertions | grep "FRITZ!Box phone"` shows the assertion; unplug power → it disappears; replug → it returns; toggling "Keep Mac awake" in Settings off → it disappears.
2. Sleep the Mac briefly (Apple menu > Sleep), wake it: status goes through "Connecting…" back to "Connected", and a call made to the Fritz!Box number during sleep shows as missed in History.
3. Switch Wi-Fi networks: within ~5 s the app re-registers.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: keep-awake assertion, wake and network-change handling" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Launch at login, documentation and final verification

**Files:**
- Create: `README.md`
- Modify: `App/Views/SettingsView.swift`, `App/AppEnvironment.swift`

**Interfaces:**
- Consumes: `AppSettings.launchAtLogin` (Task 5), `AppEnvironment.applySettings` (Task 6).

- [ ] **Step 1: Apply launch-at-login in `applySettings`**

In `AppEnvironment.swift` add `import ServiceManagement` and at the top of `applySettings`, after saving:
```swift
        do {
            if s.launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { core.reportError("Launch at login failed: \(error.localizedDescription)") }
```
In `SettingsView` add `Toggle("Launch at login", isOn: $s.launchAtLogin)` to the "Behaviour" section.

- [ ] **Step 2: Write `README.md`**

Contents (write each as concise prose/lists, no placeholders):
- What it is and the v1 feature list.
- Build: `brew install xcodegen go`, `scripts/build-pjsip.sh`, set Team ID/bundle prefix in `project.yml`, `xcodegen`, open `FritzPhone.xcodeproj`, run.
- Fritz!Box prerequisites: (1) create an IP telephone (Telephony > Telephony Devices) and use its user/password as the SIP login; (2) create a user with "Phone" and "FRITZ!Box settings" rights and enable "Allow access for applications" (TR-064) under Home Network > Network > Network Settings; (3) for remote use create a WireGuard connection for the Mac (Internet > Permit Access > VPN (WireGuard)) and paste its `.conf` into Settings.
- Behaviour notes: the Mac only rings while awake (the app holds a no-idle-sleep assertion on AC power); missed calls appear in History after wake; the Fritz!Box certificate is pinned on first use (to reset after replacing the Fritz!Box run `defaults delete <bundle id> tr064CertFingerprint`).
- Dev tools: `fritzdump`, `siptool` usage (env vars).
- Out of scope in v1 and ideas for later (CallKit check on macOS, iPhone companion, Call Directory extension).

- [ ] **Step 3: Full verification**

Run: `cd Packages/PhoneKit && swift test 2>&1 | tail -5 && cd ../.. && xcodegen && xcodebuild -scheme FritzPhone -destination 'platform=macOS' build | tail -3`
Expected: all unit tests PASS and `** BUILD SUCCEEDED **`.

Then run this manual checklist with the user and report each line as pass/fail (do not claim success without it):
1. At home: starts "Connected" without starting the VPN; phone book and history load.
2. Outgoing call to a mobile: rings, two-way audio, mute silences the mic, DTMF tones are heard by an IVR, hang-up works.
3. Incoming call: notification with phone book name, Answer connects, Decline rejects; unknown number shows the number.
4. Away from home (hotspot): app starts the VPN itself and everything above still works; quitting stops the VPN.
5. Wrong SIP password: "Login rejected" with no retry storm. Wrong TR-064 password: cached contacts with a notice.
6. Sleep/wake and Wi-Fi switch recover automatically; the keep-awake assertion follows AC/battery.
7. Launch at login toggle works after a re-login.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: launch at login and README" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

## Self-Review (spec coverage)

| Spec requirement | Task |
|---|---|
| Menu bar SwiftUI app, popover, settings | 1, 6 |
| `FritzTR064`: phone book, call list, number→name lookup, TOFU pinning, digest auth | 2, 3, 4 |
| `AppCore` startup flow (probe → VPN → SIP → phone book), errors, backoff, shutdown rules | 5 |
| Phone book cache and notice on failure | 5 (`ContactCache`), 6 (live check) |
| Secrets only in Keychain | 5 (`KeychainSecretStore`), 10 (shared keychain item for the tunnel) |
| PJSIP xcframework, ObjC++ bridge, G.722/PCMA/PCMU, mute, DTMF | 7, 8 |
| Dial, receive, notification with Answer/Decline, caller name | 8, 9 |
| Call history incl. missed calls after wake | 4, 5, 6, 11 |
| WireGuard `NetworkExtension` packet tunnel, automatic start/stop | 10 |
| `IOPMAssertion` on AC, sleep/wake re-register, network-change re-register | 5 (logic + tests), 11 (adapters) |
| Mic permission handling | 9 |
| Launch at login | 12 |
| Out of scope (editing, hold, video, multi-account, push) | not implemented, by design |

Deviations from the spec, deliberate: HTTP digest uses URLSession's built-in handling instead of custom digest code (so there are no digest unit tests; the fake-transport and live checks cover the flow); the phone book loads before SIP registration so it works even when SIP login fails.
