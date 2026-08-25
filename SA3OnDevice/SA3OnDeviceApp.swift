import SwiftUI

@main
struct SA3OnDeviceApp: App {
    @StateObject private var engine = SA3Engine()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(engine)
        }
    }
}
