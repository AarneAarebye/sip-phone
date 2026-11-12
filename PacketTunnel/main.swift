// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation
import NetworkExtension

// System-extension entry point: hand control to NetworkExtension, which instantiates the provider
// class named in Info.plist (NetworkExtension > NEProviderClasses).
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
