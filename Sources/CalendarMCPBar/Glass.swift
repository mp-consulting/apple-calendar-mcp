import SwiftUI

// Liquid Glass on macOS 26+, with material fallbacks so the app also builds
// with older SDKs (Swift < 6.2) and runs on macOS 14–15.

extension View {
    /// Glass button style (prominent = tinted glass for the primary action).
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
        #else
        if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        #endif
    }
}
