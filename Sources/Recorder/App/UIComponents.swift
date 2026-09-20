import AppKit
import SwiftUI

enum TechButtonKind { case primary, secondary, quiet, danger }

struct TechButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    var kind: TechButtonKind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Font(Theme.labelFont))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 8 : 11)
            .frame(minHeight: compact ? 24 : 28)
            .background(background(for: configuration))
            .overlay(Rectangle().stroke(border, lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.35)
            .offset(y: configuration.isPressed && !reduceMotion ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.hover), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.press), value: configuration.isPressed)
            .onHover { hovered = $0 && isEnabled }
    }

    private func background(for configuration: Configuration) -> Color {
        if configuration.isPressed { return background.opacity(0.68) }
        guard hovered else { return background }
        switch kind {
        case .primary: return Theme.accentColor.opacity(0.88)
        case .secondary, .quiet: return Theme.bgHoverColor
        case .danger: return Theme.dangerColor.opacity(0.12)
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: Theme.bgWindowColor
        case .secondary: Theme.textPrimaryColor
        case .quiet: hovered ? Theme.textPrimaryColor : Theme.textSecondaryColor
        case .danger: Theme.dangerColor
        }
    }

    private var background: Color {
        switch kind {
        case .primary: Theme.accentColor
        case .secondary: Theme.bgControlColor
        case .quiet, .danger: .clear
        }
    }

    private var border: Color {
        switch kind {
        case .primary: Theme.accentColor
        case .secondary: hovered ? Theme.strokeStrongColor : Theme.strokeColor
        case .quiet: .clear
        case .danger: .clear
        }
    }
}

struct TechSelectableTileStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .stroke(selected ? Theme.accentColor : Theme.strokeColor,
                            lineWidth: selected ? 2 : 1)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
            .contentShape(Rectangle())
    }
}

struct TechFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(Font(Theme.bodyFont))
            .foregroundStyle(Theme.textPrimaryColor)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.bgControlColor)
            .overlay(Rectangle().stroke(Theme.strokeStrongColor, lineWidth: 1))
    }
}

struct TechSearchField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat = 220

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondaryColor)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
        }
        .font(Font(Theme.bodyFont))
        .padding(.horizontal, 10)
        .frame(width: width, height: 32)
        .background(Theme.bgControlColor)
        .overlay(Rectangle().stroke(Theme.strokeStrongColor))
        .accessibilityElement(children: .contain)
    }
}

struct TechMenuLabel: View {
    let title: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
        }
        .font(Font(Theme.labelFont))
        .foregroundStyle(Theme.textPrimaryColor)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Theme.bgControlColor)
        .overlay(Rectangle().stroke(Theme.strokeStrongColor))
    }
}

struct TechToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label
                    .font(Font(Theme.bodyFont))
                    .foregroundStyle(Theme.textPrimaryColor)
                Spacer(minLength: 8)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(configuration.isOn ? Theme.accentColor : Theme.bgControlColor)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.strokeStrongColor))
                    RoundedRectangle(cornerRadius: 1)
                        .fill(configuration.isOn ? Theme.bgWindowColor : Theme.textSecondaryColor)
                        .frame(width: 12, height: 12)
                        .offset(x: configuration.isOn ? 20 : 4)
                }
                .frame(width: 36, height: 20)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: configuration.isOn)
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// A single disclosure row, with its chevron aligned to the inspector's value rail.
struct InspectorDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack {
                    configuration.label
                    Spacer(minLength: 8)
                    Image(systemName: "plus").font(.system(size: 10, weight: .medium))
                        .rotationEffect(.degrees(configuration.isExpanded ? 45 : 0))
                }
                .font(Font(Theme.labelFont))
                .foregroundStyle(Theme.textSecondaryColor)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
        .padding(.top, 6)
        .overlay(alignment: .top) { Theme.strokeColor.frame(height: 1) }
    }
}

/// The shared compact choice rail used anywhere a small, mutually-exclusive set replaces content
/// in place. Unlike the platform segmented picker, this keeps Signal UI's square geometry and the
/// same selected/disabled contrast in the gallery, inspector and sheets.
struct TechSegmentedControl<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [(Option, String)]
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button { selection = option.0 } label: {
                    Text(option.1).frame(maxWidth: .infinity)
                }
                    .buttonStyle(TechButtonStyle(kind: selection == option.0 ? .primary : .quiet,
                                                 compact: true))
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(selection == option.0 ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.bgControlColor)
        .overlay(Rectangle().stroke(Theme.strokeColor))
        .opacity(isEnabled ? 1 : 0.35)
    }
}

struct TechSectionLabel: View {
    let index: String
    let title: String
    var color = Theme.accentColor

    var body: some View {
        HStack(spacing: 8) {
            Text(index)
                .foregroundStyle(Theme.bgWindowColor)
                .frame(width: 26, height: 20)
                .background(color)
            Text(title).font(Font(Theme.headingFont(24))).foregroundStyle(Theme.textPrimaryColor)
            Spacer(minLength: 0)
        }
        .font(Font(Theme.labelFont))
        .accessibilityElement(children: .combine)
    }
}

struct TechStatus: View {
    let title: String
    var color = Theme.layoutColor

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(Font(Theme.captionFont))
                .foregroundStyle(Theme.textSecondaryColor)
        }
    }
}

struct TechPanel<Content: View>: View {
    let index: String
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TechSectionLabel(index: index, title: title)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bgPanelColor)
        .overlay(Rectangle().stroke(Theme.strokeColor, lineWidth: 1))
        .overlay { TechCornerMarks() }
    }
}

/// Structural accents shared by the gallery panels and floating capture surface.
struct TechCornerMarks: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let w = geometry.size.width, h = geometry.size.height
                for (x, y, dx, dy) in [(0.0, 0.0, 1.0, 1.0), (w, 0.0, -1.0, 1.0),
                                       (0.0, h, 1.0, -1.0), (w, h, -1.0, -1.0)] {
                    path.move(to: CGPoint(x: x, y: y + dy * 7))
                    path.addLine(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x + dx * 7, y: y))
                }
            }
            .stroke(Theme.textPrimaryColor, lineWidth: 1)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct TechGridBackground: View {
    var step: CGFloat = 32

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for x in stride(from: 0, through: size.width, by: step) {
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: 0, through: size.height, by: step) {
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(Theme.gridColor.opacity(0.44)), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

private struct SignalWindowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Font(Theme.bodyFont))
            .foregroundStyle(Theme.textPrimaryColor)
            .tint(Theme.accentColor)
            .background(Theme.bgWindowColor)
            .preferredColorScheme(.dark)
    }
}

extension View {
    func signalWindow() -> some View { modifier(SignalWindowModifier()) }
}

/// AppKit counterpart to the SwiftUI components above. Editor chrome and the timeline are AppKit,
/// so their controls route through this same contract instead of carrying private lookalike styles.
enum TechAppKit {
    static func button(_ title: String, kind: TechButtonKind = .secondary, compact: Bool = false,
                       target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        style(button, kind: kind, compact: compact)
        return button
    }

    static func style(_ button: NSButton, kind: TechButtonKind = .secondary, compact: Bool = false) {
        button.isBordered = false
        button.font = Theme.labelFont
        button.wantsLayer = true
        button.layer?.cornerRadius = Theme.Radius.control
        button.layer?.borderWidth = kind == .secondary ? 1 : 0
        if let height = button.constraints.first(where: { $0.identifier == "TechAppKit.height" }) {
            height.constant = compact ? 26 : 34
        } else {
            let height = button.heightAnchor.constraint(equalToConstant: compact ? 26 : 34)
            height.identifier = "TechAppKit.height"
            height.isActive = true
        }
        switch kind {
        case .primary:
            button.contentTintColor = Theme.bgWindow
            button.layer?.backgroundColor = Theme.accent.cgColor
            button.layer?.borderColor = Theme.accent.cgColor
        case .secondary:
            button.contentTintColor = Theme.textPrimary
            button.layer?.backgroundColor = Theme.bgControl.cgColor
            button.layer?.borderColor = Theme.stroke.cgColor
        case .quiet:
            button.contentTintColor = Theme.textSecondary
            button.layer?.backgroundColor = NSColor.clear.cgColor
            button.layer?.borderColor = NSColor.clear.cgColor
        case .danger:
            button.contentTintColor = Theme.danger
            button.layer?.backgroundColor = NSColor.clear.cgColor
            button.layer?.borderColor = Theme.danger.cgColor
        }
    }

    static func rule() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.stroke.cgColor
        return view
    }

    static func styleSurface(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.bgPanel.cgColor
    }
}

/// Lets the gallery render the exact AppKit control used by native editor chrome.
struct TechAppKitButtonPreview: NSViewRepresentable {
    let title: String
    var kind: TechButtonKind = .secondary

    func makeNSView(context: Context) -> NSButton {
        TechAppKit.button(title, kind: kind, compact: true, target: nil, action: nil)
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        nsView.title = title
        TechAppKit.style(nsView, kind: kind, compact: true)
    }
}

/// Reveal only the incoming context; outgoing forms are removed immediately.
struct InspectorReveal: ViewModifier {
    let identity: String
    let order: Int
    var enabled = true
    @State private var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.opacity(visible ? 1 : 0.65)
            .offset(y: visible || reduceMotion ? 0 : 4)
            .task(id: identity) {
                guard enabled && !reduceMotion else { visible = true; return }
                visible = false
                do { try await Task.sleep(for: .milliseconds(order * 40)) } catch { return }
                withAnimation(.easeOut(duration: 0.18)) { visible = true }
            }
    }
}
