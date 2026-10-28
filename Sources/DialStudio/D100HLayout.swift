import SwiftUI
import UlanziKit

/// Schematic geometry of the D100H. Drawn, not photographed.
enum D100HLayout {
    static let aspect: CGFloat = 1.10
    struct Key: Identifiable {
        let control: Control
        let x: CGFloat
        let y: CGFloat
        let w: CGFloat
        let h: CGFloat
        var id: Control { control }
    }
    static let keys: [Key] = [
        Key(control: .topLeft, x: 0.2375, y: 0.1575, w: 0.255, h: 0.215),
        Key(control: .topMiddle, x: 0.5, y: 0.1575, w: 0.25, h: 0.215),
        Key(control: .topRight, x: 0.7625, y: 0.1575, w: 0.255, h: 0.215),
        Key(control: .leftTop, x: 0.0575, y: 0.4125, w: 0.065, h: 0.135),
        Key(control: .leftBottom, x: 0.0575, y: 0.5825, w: 0.065, h: 0.135),
        Key(control: .rightTop, x: 0.9425, y: 0.4125, w: 0.065, h: 0.135),
        Key(control: .rightBottom, x: 0.9425, y: 0.5825, w: 0.065, h: 0.135)
    ]
    static let topKeys: Set<Control> = [.topLeft, .topMiddle, .topRight]
    static let knobX: CGFloat = 0.5
    static let knobY: CGFloat = 0.635
    static let knobDiameter: CGFloat = 0.52
}

/// Occupancy diagram: which controls a layer actually covers.
struct DeviceThumbnail: View {
    let layer: StudioLayer
    let size: CGFloat
    var highlight: Color = .accentColor
    private var height: CGFloat { size * D100HLayout.aspect }
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: size * 0.14)
                .fill(Color.primary.opacity(0.08))
                .frame(width: size * 0.82, height: height * 0.96)
                .position(x: size * 0.5, y: height * 0.5)
            HStack(spacing: max(1, size * 0.02)) {
                ForEach([Control.topLeft, .topMiddle, .topRight]) { control in
                    RoundedRectangle(cornerRadius: max(0.8, size * 0.02))
                        .fill(isAssigned(control) ? highlight.opacity(0.9) : Color.primary.opacity(0.14))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: size * 0.775, height: height * 0.215)
            .position(x: size * 0.5, y: height * 0.1575)
            ForEach(D100HLayout.keys.filter { !D100HLayout.topKeys.contains($0.control) }) { key in
                RoundedRectangle(cornerRadius: max(0.8, size * 0.02))
                    .fill(isAssigned(key.control) ? highlight.opacity(0.9) : Color.primary.opacity(0.14))
                    .frame(width: size * key.w, height: height * key.h)
                    .position(x: size * key.x, y: height * key.y)
            }
            Circle()
                .fill(isAssigned(.dial) ? highlight.opacity(0.9) : Color.primary.opacity(0.10))
                .frame(width: size * D100HLayout.knobDiameter, height: size * D100HLayout.knobDiameter)
                .position(x: size * D100HLayout.knobX, y: height * D100HLayout.knobY)
        }
        .frame(width: size, height: height)
        .accessibilityHidden(true)
    }
    private func isAssigned(_ control: Control) -> Bool {
        layer.bindings.contains { $0.enabled && $0.control == control }
    }
}
