import SwiftUI

/// Isolated motion study: edits never touch a recording or the real editor model.
struct TimelineInteractionPrototype: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: Int? = 0
    @State private var hoverTime: Double?
    @State private var playhead = 8.0
    @State private var starts = [2.0, 5.0, 12.0, 18.0]
    @State private var lengths = [11.0, 6.0, 9.0, 5.0]
    @State private var dragOrigin: Double?
    @State private var activeDrag: Int?
    @State private var trimming = false
    @State private var message = "Drag a block or its right edge. Drag the ruler to scrub."
    @State private var audition = false
    @State private var revealID = 0

    init(autoAudition: Bool = false) {
        _audition = State(initialValue: autoAudition)
        _revealID = State(initialValue: autoAudition ? 1 : 0)
    }

    private let names = ["Video", "Zoom", "Layout", "Mask"]
    private let colors = [Theme.clipColor, Theme.zoomColor, Theme.layoutColor, Theme.maskColor]
    private var motion: Animation? {
        reduceMotion ? nil : .spring(response: Theme.Motion.springResponse,
                                     dampingFraction: Theme.Motion.springDamping)
    }

    nonisolated static func snapped(_ value: Double, upper: Double) -> Double {
        min(max((value * 2).rounded() / 2, 0), max(0, upper))
    }

    var body: some View {
        TechPanel(index: "06", title: "Timeline / interaction study") {
            HStack(spacing: 12) {
                Button(audition ? "Stop preview" : "Replay reveals") {
                    if audition { audition = false }
                    else { revealID += 1; audition = true }
                }
                    .buttonStyle(TechButtonStyle(compact: true))
                Button("Reset") {
                    audition = false
                    starts = [2, 5, 12, 18]; lengths = [11, 6, 9, 5]
                    playhead = 8; selected = 0
                    message = "Drag a block or its right edge. Drag the ruler to scrub."
                }.buttonStyle(TechButtonStyle(kind: .quiet, compact: true))
                Spacer()
                Text(String(format: "%05.2f s", playhead))
                    .font(Font(Theme.timecodeFont(12)))
                    .contentTransition(.numericText())
            }
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 64)
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 12) {
                        ruler(width: width).padding(.leading, 64)
                        ForEach(0..<4) { lane in
                            HStack(spacing: 12) {
                                Text(names[lane]).font(Font(Theme.captionFont))
                                    .foregroundStyle(Theme.textSecondaryColor)
                                    .frame(width: 52, alignment: .leading)
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(Theme.bgControlColor)
                                    if activeDrag == lane, !trimming, let dragOrigin {
                                        Rectangle().stroke(colors[lane].opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                            .frame(width: width * lengths[lane] / 30, height: 24)
                                            .offset(x: width * dragOrigin / 30)
                                            .allowsHitTesting(false)
                                    }
                                    block(lane, width: width)
                                }.frame(height: 28)
                            }
                            .modifier(TimelineReveal(trigger: revealID, delay: Double(lane) * 0.085))
                        }
                    }
                    if let hoverTime {
                        Rectangle().fill(Theme.textPrimaryColor.opacity(0.25))
                            .frame(width: 1, height: 174)
                            .offset(x: 64 + width * hoverTime / 30, y: 24)
                            .allowsHitTesting(false)
                    }
                    VStack(spacing: 0) {
                        Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9))
                        Rectangle().frame(width: 1)
                    }
                    .foregroundStyle(Theme.textPrimaryColor)
                    .frame(width: 10, height: 184)
                    .offset(x: 59 + width * playhead / 30, y: 14)
                    .allowsHitTesting(false)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hoverTime = min(30, max(0, (point.x - 64) / width * 30))
                    case .ended: hoverTime = nil
                    }
                }
            }.frame(height: 198).coordinateSpace(name: "motionTimeline")
            if let selected {
                HStack(spacing: 20) {
                    Rectangle().fill(colors[selected]).frame(width: 3, height: 26)
                    Text(names[selected]).font(Font(Theme.headingFont(26)))
                        .frame(width: 60, alignment: .leading)
                        .modifier(TimelineReveal(trigger: selected + revealID * 10, delay: 0))
                    Text(String(format: "In  %05.1f s", starts[selected]))
                        .modifier(TimelineReveal(trigger: selected + revealID * 10, delay: 0.075))
                    Text(String(format: "Out  %05.1f s", starts[selected] + lengths[selected]))
                        .modifier(TimelineReveal(trigger: selected + revealID * 10, delay: 0.15))
                    Spacer()
                    Button("Deselect") { withAnimation(motion) { self.selected = nil } }
                        .buttonStyle(TechButtonStyle(kind: .quiet, compact: true))
                }
                .font(Font(Theme.captionFont))
                .padding(10)
                .background(Theme.bgControlColor)
                .overlay(alignment: .bottom) { colors[selected].frame(height: 1) }
                .modifier(TimelineReveal(trigger: selected + revealID * 10, delay: 0))
            }
            HStack {
                Text(message)
                Spacer()
                Text("Snap 0.5 s").foregroundStyle(Theme.textPrimaryColor)
            }.font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
        }
        .frame(height: 390)
        .task(id: audition) {
            guard audition else { return }
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            // Bounded audition; no perpetual animation or idle timer.
            for lane in 0..<4 {
                guard !Task.isCancelled else { return }
                withAnimation(motion) { selected = lane; playhead = starts[lane] }
                message = "\(names[lane]) selected"
                do { try await Task.sleep(for: .milliseconds(1000)) } catch { return }
            }
            audition = false
        }
    }

    private func ruler(width: CGFloat) -> some View {
        HStack {
            ForEach(0..<7) { tick in
                Text(String(format: "00:%02d", tick * 5))
                if tick < 6 { Spacer(minLength: 0) }
            }
        }
        .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
        .frame(height: 24)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            audition = false
            playhead = min(30, max(0, value.location.x / width * 30))
            message = String(format: "Scrub  %.2f s", playhead)
        })
        .accessibilityLabel("Playhead")
        .accessibilityValue(String(format: "%.1f seconds", playhead))
        .accessibilityAdjustableAction { direction in
            playhead = min(30, max(0, playhead + (direction == .increment ? 0.5 : -0.5)))
        }
    }

    private func block(_ lane: Int, width: CGFloat) -> some View {
        let blockWidth = width * lengths[lane] / 30
        return PrototypeTimelineBlock(title: names[lane], color: colors[lane],
                                      selected: selected == lane, dragging: activeDrag == lane) {
            audition = false
            withAnimation(motion) { selected = lane }
            message = "\(names[lane]) selected"
        }
        .frame(width: blockWidth, height: 24)
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("motionTimeline")).onChanged { value in
            audition = false
            if dragOrigin == nil { dragOrigin = starts[lane]; trimming = false }
            activeDrag = lane; selected = lane
            starts[lane] = min(30 - lengths[lane], max(0,
                (dragOrigin ?? starts[lane]) + value.translation.width / width * 30))
            message = String(format: "Move %@  %.1f s", names[lane], starts[lane])
        }.onEnded { _ in
            withAnimation(motion) {
                starts[lane] = Self.snapped(starts[lane], upper: 30 - lengths[lane])
                activeDrag = nil
            }
            dragOrigin = nil
            message = String(format: "Placed %@ at %.1f s", names[lane], starts[lane])
        })
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.bgWindowColor.opacity(0.65))
                .frame(width: 3, height: 12)
                .frame(width: 14, height: 28)
                .contentShape(Rectangle())
                .opacity(selected == lane ? 1 : 0.35)
                .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("motionTimeline")).onChanged { value in
                    audition = false
                    if dragOrigin == nil { dragOrigin = lengths[lane]; trimming = true }
                    activeDrag = lane; selected = lane
                    lengths[lane] = min(30 - starts[lane], max(1,
                        (dragOrigin ?? lengths[lane]) + value.translation.width / width * 30))
                    message = String(format: "Trim %@  %.1f s", names[lane], lengths[lane])
                }.onEnded { _ in
                    withAnimation(motion) {
                        lengths[lane] = max(1, Self.snapped(lengths[lane], upper: 30 - starts[lane]))
                        activeDrag = nil
                    }
                    dragOrigin = nil
                })
                .accessibilityLabel("Trim \(names[lane])")
                .accessibilityAdjustableAction { direction in
                    lengths[lane] = min(30 - starts[lane], max(1, lengths[lane] + (direction == .increment ? 0.5 : -0.5)))
                }
        }
        .offset(x: width * starts[lane] / 30)
    }
}

private struct PrototypeTimelineBlock: View {
    let title: String
    let color: Color
    let selected: Bool
    let dragging: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        Group {
            HStack {
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(Font(Theme.captionFont)).foregroundStyle(Theme.bgWindowColor)
            .padding(.horizontal, 8).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(color)
            .overlay {
                Theme.bgWindowColor.opacity(hovered ? 0.08 : 0)
                    .allowsHitTesting(false)
            }
            .overlay {
                Rectangle().stroke(Theme.textPrimaryColor, lineWidth: selected ? 1 : 0)
                    .padding(selected ? -3 : 0)
            }
            .offset(y: reduceMotion ? 0 : dragging ? -4 : hovered ? -1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .focusable()
        .onKeyPress(.return) { action(); return .handled }
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.hover), value: hovered)
        .animation(reduceMotion ? nil : .spring(response: Theme.Motion.springResponse,
                                                dampingFraction: Theme.Motion.springDamping), value: selected)
        .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.drag), value: dragging)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Each reveal owns its phase so interrupted selections restart cleanly and delayed work cancels.
private struct TimelineReveal: ViewModifier {
    let trigger: Int
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 7)
            .mask(alignment: .leading) {
                Rectangle().scaleEffect(x: visible || reduceMotion ? 1 : 0, y: 1, anchor: .leading)
            }
            .task(id: trigger) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { visible = false }
                do { try await Task.sleep(for: .seconds(reduceMotion ? 0 : delay + 0.025)) }
                catch { return }
                withAnimation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1,
                                                                duration: Theme.Motion.reveal)) {
                    visible = true
                }
            }
    }
}
