import SwiftUI

/// Settings › General › Save power (see Power).
struct PowerLine: View {
    @ObservedObject private var power = Power.shared

    var body: some View {
        Line("Save power", power.saving
             ? "Saving now: pages at 60 Hz, background tabs sleep after 5 minutes, new pages wait for a click to play, and the new tab stays still"
             : "Pages at 60 Hz, background tabs sleep after 5 minutes, new pages wait for a click to play, and the new tab stays still") {
            Picker("", selection: $power.mode) {
                ForEach(Power.Mode.allCases) { mode in
                    Text(mode.title.said).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}
