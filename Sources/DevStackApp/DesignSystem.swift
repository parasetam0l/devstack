import AppKit
import Combine
import DevStackCore
import SwiftUI

enum DevStackDesign {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor(calibratedWhite: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.65 : 0.35, alpha: 1)
    })
    static let success = Color.primary
    static let radius: CGFloat = 12
    static let icon: NSImage? = {
        DevStackResources.bundle.url(forResource: "DevStackIcon", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }()

    // Open layers stay distinct at menu-bar size; the terminal mark echoes the app icon.
    static var menuBarIcon: NSImage {
        let image = NSImage(size: NSSize(width: 19, height: 19), flipped: false) { _ in
            NSColor.black.setStroke()
            let layers = NSBezierPath()
            layers.lineWidth = 1.35
            layers.lineCapStyle = .round
            layers.lineJoinStyle = .round
            layers.move(to: NSPoint(x: 2.2, y: 12.7))
            layers.line(to: NSPoint(x: 9.5, y: 16.4))
            layers.line(to: NSPoint(x: 16.8, y: 12.7))
            layers.line(to: NSPoint(x: 9.5, y: 9))
            layers.close()
            for y: CGFloat in [9.3, 5.9] {
                layers.move(to: NSPoint(x: 2.2, y: y))
                layers.line(to: NSPoint(x: 9.5, y: y - 3.7))
                layers.line(to: NSPoint(x: 16.8, y: y))
            }
            layers.stroke()
            let terminal = NSBezierPath()
            terminal.lineWidth = 1.1
            terminal.lineCapStyle = .round
            terminal.lineJoinStyle = .round
            terminal.move(to: NSPoint(x: 7, y: 14))
            terminal.line(to: NSPoint(x: 8.8, y: 13))
            terminal.line(to: NSPoint(x: 7, y: 12))
            terminal.move(to: NSPoint(x: 10.5, y: 12.2))
            terminal.line(to: NSPoint(x: 12.2, y: 12.2))
            terminal.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

}

struct BrandIcon: View {
    var size: CGFloat = 42
    var body: some View {
        Group {
            if let icon = DevStackDesign.icon {
                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "square.3.layers.3d").resizable().scaledToFit().foregroundStyle(DevStackDesign.accent).padding(size * 0.15)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct WorkspaceBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color.black : Color.white).opacity(0.12)
        }.ignoresSafeArea()
    }
}

struct WorkspacePage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 8) {
                VStack(alignment: .leading, spacing: 10) { content }
            }
                .frame(maxWidth: 1040, alignment: .leading)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(WorkspaceBackground())
        .controlSize(.small)
        .font(.system(size: 12))
    }
}

struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 20, weight: .semibold)).tracking(-0.4)
            if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct SurfacePanel<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

struct StatusBadge: View {
    let title: String
    var color: Color = .secondary
    var dot = false
    var dotColor: Color? = nil
    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(dotColor ?? color).frame(width: 5, height: 5) }
            Text(title).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.1), in: Capsule())
    }
}

struct FeatureIcon: View {
    let symbol: String
    var color: Color = .secondary
    var body: some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .medium))
            .foregroundStyle(color).frame(width: 26, height: 26)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
    }
}

struct EmptyWorkspace: View {
    let symbol: String
    let title: String
    let description: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 23, weight: .light))
                .foregroundStyle(DevStackDesign.accent).frame(width: 42, height: 42)
                .background(DevStackDesign.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
            Text(description).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(DevStackGlassButtonStyle()).controlSize(.small).padding(.top, 4)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 14)
    }
}

struct InfoNotice: View {
    let symbol: String
    let title: String
    let message: String
    var color: Color = .secondary
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CopyValueRow: View {
    let label: String
    let value: String
    @StateObject private var state = CopyValueState()
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                state.copied = true
                Task { try? await Task.sleep(for: .seconds(2)); state.copied = false }
            } label: { Image(systemName: state.copied ? "checkmark" : "doc.on.doc").foregroundStyle(state.copied ? DevStackDesign.accent : .secondary) }
            .buttonStyle(.borderless).help("Copy \(label.lowercased())").accessibilityLabel("Copy \(label.lowercased())")
        }
    }
}

@MainActor private final class CopyValueState: ObservableObject { @Published var copied = false }

extension ServicePhase {
    var color: Color {
        switch self {
        case .running: DevStackDesign.success
        case .failed: .red
        case .starting, .stopping: .orange
        case .stopped: .secondary
        }
    }

    /// Accent for the status dot only, so running chips show a green indicator without tinting the label.
    var dotColor: Color? {
        self == .running ? .green : nil
    }
}

extension ServiceKind {
    var icon: String {
        switch self {
        case .apache, .nginx: "globe"
        case .php74, .php84, .php85: "chevron.left.forwardslash.chevron.right"
        case .mysql57, .mysql84, .postgresql18: "externaldrive"
        case .mailpit: "envelope"
        }
    }
}

extension RuntimeKind {
    var displayName: String {
        switch self {
        case .apache: "Apache"
        case .nginx: "Nginx"
        case .php: "PHP"
        case .mysql: "MySQL"
        case .postgresql: "PostgreSQL"
        case .mailpit: "Mailpit"
        case .adminer: "Adminer"
        case .phpMyAdmin: "phpMyAdmin"
        case .composer: "Composer"
        case .openssl: "OpenSSL"
        case .phpExtension: "PHP extension"
        case .library: "Library"
        }
    }
}

struct DevStackGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(enabled ? Color.primary : Color.secondary)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .glassEffect(.regular.interactive(), in: .capsule)
            .opacity(enabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct DevStackProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 13).padding(.vertical, 5)
            .glassEffect(.regular.tint(DevStackDesign.accent.opacity(0.35)).interactive(), in: .capsule)
            .opacity(enabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
