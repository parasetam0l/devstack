import AppKit
import Combine
import DevStackCore
import SwiftUI

enum DevStackDesign {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.27, green: 0.81, blue: 0.79, alpha: 1)
            : NSColor(srgbRed: 0.02, green: 0.43, blue: 0.46, alpha: 1)
    })
    static let success = Color(red: 0.13, green: 0.64, blue: 0.43)
    static let radius: CGFloat = 14
    static let icon: NSImage? = {
        DevStackResources.bundle.url(forResource: "DevStackIcon", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }()

    // A template version of the app's three-layer stack for the macOS menu bar.
    static var menuBarIcon: NSImage {
        let image = NSImage(size: NSSize(width: 19, height: 19), flipped: false) { _ in
            NSColor.black.setFill()
            for y: CGFloat in [4, 8, 12] {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 1.5, y: y + 1))
                path.curve(to: NSPoint(x: 3, y: y + 2.5), controlPoint1: NSPoint(x: 1.5, y: y + 1.7), controlPoint2: NSPoint(x: 2.2, y: y + 2.1))
                path.line(to: NSPoint(x: 8.1, y: y + 5.2))
                path.curve(to: NSPoint(x: 10.9, y: y + 5.2), controlPoint1: NSPoint(x: 9, y: y + 5.7), controlPoint2: NSPoint(x: 10, y: y + 5.7))
                path.line(to: NSPoint(x: 16, y: y + 2.5))
                path.curve(to: NSPoint(x: 17.5, y: y + 1), controlPoint1: NSPoint(x: 16.8, y: y + 2.1), controlPoint2: NSPoint(x: 17.5, y: y + 1.7))
                path.line(to: NSPoint(x: 17.5, y: y - 0.2))
                path.line(to: NSPoint(x: 10.3, y: y - 3.7))
                path.curve(to: NSPoint(x: 8.7, y: y - 3.7), controlPoint1: NSPoint(x: 9.8, y: y - 4), controlPoint2: NSPoint(x: 9.2, y: y - 4))
                path.line(to: NSPoint(x: 1.5, y: y - 0.2))
                path.close(); path.fill()
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setStroke()
            let glyph = NSBezierPath()
            glyph.lineWidth = 1.2; glyph.lineCapStyle = .round; glyph.lineJoinStyle = .round
            glyph.move(to: NSPoint(x: 7, y: 15.1)); glyph.line(to: NSPoint(x: 9.4, y: 13.8)); glyph.line(to: NSPoint(x: 7.4, y: 12.7))
            glyph.move(to: NSPoint(x: 10.6, y: 12.6)); glyph.line(to: NSPoint(x: 12.7, y: 12.6)); glyph.stroke()
            NSGraphicsContext.restoreGraphicsState()
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
            LinearGradient(colors: [DevStackDesign.accent.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
        }.ignoresSafeArea()
    }
}

struct WorkspacePage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 12) {
                VStack(alignment: .leading, spacing: 20) { content }
            }
                .frame(maxWidth: 1040, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(WorkspaceBackground())
    }
}

struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 25, weight: .semibold)).tracking(-0.4)
            if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct SurfacePanel<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let title {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

struct StatusBadge: View {
    let title: String
    var color: Color = .secondary
    var dot = false
    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(color).frame(width: 5, height: 5) }
            Text(title).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(color.opacity(0.1), in: Capsule())
    }
}

struct FeatureIcon: View {
    let symbol: String
    var color: Color = DevStackDesign.accent
    var body: some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .medium))
            .foregroundStyle(color).frame(width: 38, height: 38)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
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
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light))
                .foregroundStyle(DevStackDesign.accent).frame(width: 76, height: 76)
                .background(DevStackDesign.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 22))
            Text(title).font(.system(size: 19, weight: .semibold, design: .rounded))
            Text(description).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.glassProminent).controlSize(.large).padding(.top, 4)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 30)
    }
}

struct InfoNotice: View {
    let symbol: String
    let title: String
    let message: String
    var color: Color = DevStackDesign.accent
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CopyValueRow: View {
    let label: String
    let value: String
    @StateObject private var state = CopyValueState()
    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
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
}

extension ServiceKind {
    var icon: String {
        switch self {
        case .apache, .nginx: "globe"
        case .php74, .php84, .php85: "chevron.left.forwardslash.chevron.right"
        case .mysql57, .mysql84: "externaldrive"
        case .mailpit: "envelope"
        }
    }
    var endpoint: String {
        switch self {
        case .apache: "8080 · 8443"
        case .nginx: "8080 · 8443"
        case .php74, .php84, .php85: "PHP-FPM"
        case .mysql57, .mysql84: "127.0.0.1:3306"
        case .mailpit: "SMTP · 1025"
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
            .padding(.horizontal, 16).padding(.vertical, 8)
            .glassEffect(.regular.interactive(), in: .capsule)
            .opacity(enabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
