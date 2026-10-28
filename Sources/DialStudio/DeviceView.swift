import SwiftUI
import UlanziKit

/// Pie slice used for the dial direction highlight, so it follows the knob.
struct HalfCircle: Shape {
    let left: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(left ? 90 : -90), endAngle: .degrees(left ? 270 : 90), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Drawn schematic of the device. Each key and each dial direction shows the
/// action assigned to it in the current layer.
struct DeviceView: View {
    let model: StudioModel

    var body: some View {
        GeometryReader { geo in
            let width = deviceWidth(geo.size)
            content(width: width, height: width * D100HLayout.aspect)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(minHeight: 180, maxHeight: .infinity)
        .padding(.horizontal, 8)
    }

    private func deviceWidth(_ available: CGSize) -> CGFloat {
        let byWidth = available.width - 24
        let byHeight = (available.height - 20) / D100HLayout.aspect
        return max(0, min(byWidth, byHeight))
    }

    private func content(width w: CGFloat, height h: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: w * 0.075)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: w * 0.075).fill(Color.primary.opacity(0.11)))
                .overlay(RoundedRectangle(cornerRadius: w * 0.075).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
                .frame(width: w * 0.82, height: h * 0.96)
                .position(x: w * 0.5, y: h * 0.5)
            ForEach(D100HLayout.keys) { key in
                keyView(key, w: w, h: h)
            }
            knobView(w: w, h: h)
        }
        .frame(width: w, height: h)
    }

    // MARK: - Keys

    @ViewBuilder private func keyView(_ key: D100HLayout.Key, w: CGFloat, h: CGFloat) -> some View {
        let isTop = D100HLayout.topKeys.contains(key.control)
        let name = actionName(key.control)
        let selected = model.selectedControl == key.control
        let held = model.deviceHeld.contains(key.control) || model.previewHeld.contains(key.control)
        let radius = max(2, min(w * 0.03, h * key.h * 0.14))
        Button { select(key.control) } label: {
            RoundedRectangle(cornerRadius: radius)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: radius).fill(fill(name: name, held: held)))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1))
                .overlay {
                    if isTop {
                        VStack(spacing: 1) {
                            Text(name ?? key.control.title)
                                .font(.system(size: max(7, w * 0.028), weight: name == nil ? .regular : .medium))
                                .foregroundStyle(name == nil ? Color.primary.opacity(0.72) : Color.primary)
                                .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.6)
                            if name != nil {
                                Text(key.control.title)
                                    .font(.system(size: max(6, w * 0.021)))
                                    .foregroundStyle(Color.primary.opacity(0.65)).lineLimit(1)
                            }
                        }.padding(.horizontal, 4).padding(.vertical, 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(width: w * key.w, height: h * key.h)
        .modifier(AssignmentDragSource(model: model, control: key.control, title: name ?? key.control.title))
        .modifier(AssignmentDropTarget(model: model, control: key.control))
        .position(x: w * key.x, y: h * key.y)
        .help(name.map { "\(key.control.title): \($0)" } ?? key.control.title)
        .accessibilityLabel(name.map { "\(key.control.title) \($0)" } ?? key.control.title)

        if !isTop {
            VStack(spacing: 1) {
                Text(name ?? key.control.title)
                    .font(.system(size: max(6.5, w * 0.023), weight: name == nil ? .regular : .medium))
                    .foregroundStyle(name == nil ? Color.primary.opacity(0.72) : Color.primary)
                    .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.6)
                if name != nil {
                    Text(key.control.title).font(.system(size: max(5.5, w * 0.018))).foregroundStyle(Color.primary.opacity(0.65)).lineLimit(1)
                }
            }
            .frame(width: w * 0.145)
            .position(x: w * (key.x < 0.5 ? 0.163 : 0.837), y: h * key.y)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Knob

    @ViewBuilder private func knobView(w: CGFloat, h: CGFloat) -> some View {
        let d = w * D100HLayout.knobDiameter
        let cx = w * D100HLayout.knobX, cy = h * D100HLayout.knobY
        let selected = model.selectedControl == .dial || model.selectedControl == .knob
        ZStack {
            Circle().fill(Color(nsColor: .windowBackgroundColor))
            Circle().fill(Color.primary.opacity(0.17))
            Circle().fill(Color(nsColor: .windowBackgroundColor))
                .padding(d * 0.06)
            Circle().fill(Color.primary.opacity(0.08))
                .padding(d * 0.06)
            Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            Circle().fill(Color.secondary.opacity(0.55))
                .frame(width: d * 0.09, height: d * 0.09)
                .offset(x: -d * 0.18, y: -d * 0.12)
        }
        .frame(width: d, height: d)
        .rotationEffect(.degrees(model.knobAngle))
        .allowsHitTesting(false)
        .position(x: cx, y: cy)
        Circle()
            .strokeBorder(selected ? Color.accentColor.opacity(0.55) : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1)
            .frame(width: d, height: d)
            .allowsHitTesting(false)
            .position(x: cx, y: cy)
        if model.selectedControl == .dial, let gesture = model.binding?.gesture {
            HalfCircle(left: gesture.isCounterclockwise)
                .fill(Color.accentColor.opacity(0.13))
                .frame(width: d, height: d)
                .allowsHitTesting(false)
                .position(x: cx, y: cy)
        }
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                dialHalf(.counterclockwise, symbol: "arrow.counterclockwise", w: w)
                dialHalf(.clockwise, symbol: "arrow.clockwise", w: w)
            }
            HStack(spacing: 0) {
                dialHalf(.pressedCounterclockwise, symbol: "arrow.counterclockwise", w: w)
                dialHalf(.pressedClockwise, symbol: "arrow.clockwise", w: w)
            }
        }
        .frame(width: d * 0.88, height: d * 0.58)
        .position(x: cx, y: cy - d * 0.04)
        Button { select(.knob) } label: {
            HStack(spacing: 3) {
                Image(systemName: "circle.circle").font(.system(size: max(6, w * 0.02)))
                Text(actionName(.knob) ?? L("押下"))
                    .font(.system(size: max(6.5, w * 0.023), weight: actionName(.knob) == nil ? .regular : .medium))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(model.selectedControl == .knob ? Color.accentColor.opacity(0.18) : Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(model.selectedControl == .knob ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: model.selectedControl == .knob ? 2 : 1))
            .foregroundStyle(actionName(.knob) == nil ? Color.primary.opacity(0.72) : Color.primary)
        }
        .buttonStyle(.plain)
        .modifier(AssignmentDragSource(model: model, control: .knob, title: actionName(.knob) ?? L("ノブ押下")))
        .modifier(AssignmentDropTarget(model: model, control: .knob))
        .frame(width: d * 0.62)
        .position(x: cx, y: cy + d * 0.32)
        .help(L("ノブ押下"))
    }

    private func dialHalf(_ gesture: GestureKind, symbol: String, w: CGFloat) -> some View {
        let name = dialName(gesture)
        return Button {
            model.selectedControl = .dial
            model.selectedBinding = model.layer?.bindings.first { $0.control == .dial && $0.gesture == gesture }?.id
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: max(7, w * 0.026))).foregroundStyle(Color.primary.opacity(0.72))
                Text(name ?? gesture.title)
                    .font(.system(size: max(6.5, w * 0.023), weight: name == nil ? .regular : .medium))
                    .foregroundStyle(name == nil ? Color.primary.opacity(0.72) : Color.primary)
                    .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.55)
                if name != nil { Text(gesture.title).font(.system(size: max(5.5, w * 0.018))).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6) }
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(AssignmentDragSource(model: model, control: .dial, gesture: gesture, title: name ?? gesture.title))
        .modifier(AssignmentDropTarget(model: model, control: .dial, gesture: gesture))
        .help((name == nil ? gesture.title : gesture.title + ": " + (name ?? "")) + L(" — ドロップで割り当て"))
    }

    // MARK: - Helpers

    private func fill(name: String?, held: Bool) -> Color {
        if held { return Color.accentColor.opacity(0.30) }
        return Color.primary.opacity(name == nil ? 0.04 : 0.10)
    }

    private func select(_ control: Control) {
        model.selectedControl = control
        model.selectedBinding = nil
    }

    private func actionName(_ control: Control) -> String? {
        let list = (model.layer?.bindings ?? []).filter { $0.enabled && $0.control == control }
        let preferred = list.first { $0.gesture == .tap } ?? list.first { $0.gesture == .press } ?? list.first
        return preferred?.name ?? (model.layerIsAboveBottom ? L("透過") : nil)
    }

    private func dialName(_ gesture: GestureKind) -> String? {
        (model.layer?.bindings ?? []).first { $0.enabled && $0.control == .dial && $0.gesture == gesture }?.name
            ?? (model.layerIsAboveBottom ? L("透過") : nil)
    }
}
