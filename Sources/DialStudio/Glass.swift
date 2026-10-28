import SwiftUI

/// macOS 26 Liquid Glass with a material fallback for older systems.
extension View {
    @ViewBuilder func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder func glassCard<S: Shape>(_ shape: S, selected: Bool = false, interactive: Bool = true) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(interactive), in: shape)
                .overlay {
                    if selected { shape.fill(Color.accentColor.opacity(0.10)) }
                }
                .overlay {
                    shape.stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
                }
        } else {
            self.background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay { if selected { shape.fill(Color.accentColor.opacity(0.10)) } }
                .overlay(shape.stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1))
        }
    }

    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}
