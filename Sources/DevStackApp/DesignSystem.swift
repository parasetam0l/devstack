import AppKit
import Combine
import DevStackCore
import SwiftUI

enum DevStackDesign {
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
                Image(systemName: "square.3.layers.3d").resizable().scaledToFit().foregroundStyle(.secondary).padding(size * 0.15)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
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

// MARK: - Native building blocks

/// A state as macOS shows it in lists and settings: a coloured dot and a
/// secondary label ("Running", "Stopped").
struct StatusLabel: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

extension StatusLabel {
    init(_ phase: ServicePhase) {
        self.init(title: phase.title, color: phase.statusColor)
    }
}

/// A value to read and copy, such as a host, a port or a path.
struct CopyableValueRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(value)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                CopyButton(value: value, label: label)
            }
        }
    }
}

struct CopyButton: View {
    let value: String
    var label: String = "value"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help("Copy \(label.lowercased())")
        .accessibilityLabel("Copy \(label.lowercased())")
    }
}

/// Something that needs attention, inside a form section: an icon, a title,
/// an explanation, and optionally an action on the trailing side.
struct NoticeRow<Accessory: View>: View {
    let symbol: String
    let title: String
    let message: String
    var tint: Color = .orange
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.vertical, 2)
    }
}

extension NoticeRow where Accessory == EmptyView {
    init(symbol: String, title: String, message: String, tint: Color = .orange) {
        self.init(symbol: symbol, title: title, message: message, tint: tint) { EmptyView() }
    }
}

/// A form section's footnote as System Settings sets it: leading, secondary,
/// in the callout size.
struct SectionFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
