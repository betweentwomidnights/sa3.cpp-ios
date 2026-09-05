import SwiftUI

@main
struct SA3OnDeviceApp: App {
    @StateObject private var engine = SA3Engine()
    /// One settings object for the whole app: the jam tab reads it, the settings sheet writes it,
    /// and the train tab shares the model set so a run trains against the base you are jamming on.
    @StateObject private var settings = SA3Settings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .environmentObject(settings)
        }
    }
}
