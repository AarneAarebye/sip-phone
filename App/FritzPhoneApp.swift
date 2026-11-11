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
