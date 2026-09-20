import AppKit
import SwiftUI
import RecorderCore

/// A spatial alternative to the nine preset buttons. All inputs share the caller's undo transaction.
/// Kept opt-in in the gallery until placement and keyboard workflows have been evaluated together.
struct PlacementPad: View {
    let position: NormPoint
    let onChange: (NormPoint) -> Void
    let onEditingChanged: (Bool) -> Void
    let onCancel: () -> Void
    @State private var origin: NormPoint?
    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let inset: CGFloat = 18
    static func point(at location: CGPoint, in size: CGSize) -> NormPoint {
        func axis(_ coordinate: CGFloat, _ extent: CGFloat) -> Double {
            guard coordinate.isFinite, extent.isFinite, extent > inset * 2 else { return 0.5 }
            return Double(min(1, max(0, (coordinate - inset) / (extent - inset * 2))))
        }
        return NormPoint(x: axis(location.x, size.width), y: axis(location.y, size.height))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Position").font(Font(Theme.headingFont(22)))
                Spacer()
                Text("\(Int((position.x * 100).rounded())) / \(Int((position.y * 100).rounded()))")
                    .font(Font(Theme.timecodeFont(11)))
                    .foregroundStyle(Theme.bgWindowColor)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(Theme.textPrimaryColor)
                    .accessibilityLabel("Position: horizontal \(Int(position.x * 100)) percent, vertical \(Int(position.y * 100)) percent")
            }
            GeometryReader { geometry in
                let bounds = CGRect(origin: .zero, size: geometry.size).insetBy(dx: Self.inset, dy: Self.inset)
                let x = bounds.minX + bounds.width * position.x
                let y = bounds.minY + bounds.height * position.y
                ZStack {
                    Theme.bgWindowColor
                    Path { path in
                        for fraction in [0.0, 0.5, 1.0] {
                            let column = bounds.minX + bounds.width * fraction
                            let row = bounds.minY + bounds.height * fraction
                            path.move(to: CGPoint(x: column, y: bounds.minY))
                            path.addLine(to: CGPoint(x: column, y: bounds.maxY))
                            path.move(to: CGPoint(x: bounds.minX, y: row))
                            path.addLine(to: CGPoint(x: bounds.maxX, y: row))
                        }
                    }.stroke(Theme.strokeColor, style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    Path { path in
                        path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                        path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                    }.stroke(Theme.strokeStrongColor, lineWidth: 1)
                    if let origin {
                        Rectangle().stroke(Theme.textSecondaryColor, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .frame(width: 28, height: 20)
                            .position(x: bounds.minX + bounds.width * origin.x, y: bounds.minY + bounds.height * origin.y)
                    }
                    Image(systemName: "camera.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.bgWindowColor)
                        .frame(width: 28, height: 24)
                        .background(Theme.layoutColor)
                        .overlay(Rectangle().stroke(Theme.textPrimaryColor, lineWidth: origin == nil ? 1 : 2))
                        .position(x: x, y: y)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        focused = true
                        if origin == nil { origin = position; onEditingChanged(true) }
                        onChange(Self.point(at: value.location, in: geometry.size))
                    }
                    .onEnded { _ in
                        guard origin != nil else { return }
                        onEditingChanged(false)
                        origin = nil
                    })
            }
            .frame(height: 84)
            .overlay(Rectangle().stroke(focused ? Theme.textPrimaryColor : hovered ? Theme.strokeStrongColor : Theme.strokeColor))
            .focusable().focused($focused)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.hover), value: hovered)
            .onMoveCommand { direction in
                guard origin == nil else { return }
                var point = position
                let step = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 0.01
                switch direction {
                case .left: point.x = max(0, point.x - step)
                case .right: point.x = min(1, point.x + step)
                case .up: point.y = max(0, point.y - step)
                case .down: point.y = min(1, point.y + step)
                default: return
                }
                onEditingChanged(true); onChange(point); onEditingChanged(false)
            }
            .onExitCommand { cancel() }
            .onDisappear { cancel() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Camera position")
            .accessibilityValue("Horizontal \(Int(position.x * 100)) percent, vertical \(Int(position.y * 100)) percent")
            .accessibilityHint("Drag to position, or use arrow keys. Precise horizontal and vertical sliders follow.")

        }
    }

    private func cancel() {
        guard origin != nil else { return }
        onCancel()
        origin = nil
    }
}
