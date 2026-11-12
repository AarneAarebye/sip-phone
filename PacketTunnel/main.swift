import Foundation
import NetworkExtension

// System-extension entry point: hand control to NetworkExtension, which instantiates the provider
// class named in Info.plist (NetworkExtension > NEProviderClasses).
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
