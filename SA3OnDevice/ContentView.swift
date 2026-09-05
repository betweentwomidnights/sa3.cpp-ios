import SwiftUI

/// Two tabs, and that is the whole shape of the app.
///
/// **jam** is the loop that gets used: create something, then continue or transform it, with undo
/// behind every step. **train** is the loop that produces the adapters jam reaches for. The
/// registry is what joins them — a run finishes there and its adapter appears as a slider here,
/// with nothing in between.
///
/// Configuration belongs to neither tab. The model set, the autoencoder adapters and the sampler
/// live in `SA3Settings` and are edited from the jam tab's settings sheet, which is what lets
/// create, continue and transform be identical below their first control.
struct ContentView: View {
    var body: some View {
        TabView {
            JamView()
                .tabItem { Label("jam", systemImage: "waveform") }
            TrainView()
                .tabItem { Label("train", systemImage: "dial.medium") }
        }
        .preferredColorScheme(.dark)
        .tint(JamControls.accent)
    }
}
