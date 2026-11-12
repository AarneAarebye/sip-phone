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
