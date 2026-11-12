// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import XCTest
import Network
@testable import SystemAdapters

final class DirectPathTests: XCTestCase {
    func testProhibitsTunnelInterfaceTypeOnTCPAndTLSParameters() {
        for p in [NWParameters.tcp, NWParameters(tls: NWProtocolTLS.Options())] {
            DirectPath.excludeVPN(p)
            let prohibited = p.prohibitedInterfaceTypes ?? []
            XCTAssertTrue(prohibited.contains(.other), "utun (VPN) interfaces are type .other")
            XCTAssertTrue(prohibited.contains(.loopback))
            XCTAssertFalse(prohibited.contains(.wifi))
            XCTAssertFalse(prohibited.contains(.wiredEthernet))
            XCTAssertNil(p.requiredInterface)
        }
    }

    func testOnlyPhysicalTypesCount() {
        XCTAssertTrue(DirectPath.isPhysical(.wifi))
        XCTAssertTrue(DirectPath.isPhysical(.wiredEthernet))
        XCTAssertTrue(DirectPath.isPhysical(.cellular))
        XCTAssertFalse(DirectPath.isPhysical(.other))
        XCTAssertFalse(DirectPath.isPhysical(.loopback))
    }

    /// Reads the current path only (no connection is made): whatever is up, no tunnel is ever listed.
    func testPhysicalInterfacesNeverIncludeTunnels() async {
        let found = await DirectPath.physicalInterfaces()
        XCTAssertTrue(found.allSatisfy { DirectPath.isPhysical($0.type) })
        XCTAssertFalse(found.contains { $0.name.hasPrefix("utun") })
    }
}
