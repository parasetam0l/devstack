import AppKit
import SwiftUI

// Compact building blocks for the workspace pages. A developer scans these
// pages many times a day, so rows stay on one line and margins stay narrow;
// the window chrome (sidebar and toolbar) is the system's own Liquid Glass.

/// A scrolling page of panels.
struct PanelPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// A titled group of one-line rows on a rounded background, with a hairline
/// between rows. The accessory sits at the trailing end of the title.
struct Panel<Content: View, Accessory: View>: View {
    var title: String?
    var note: String?
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(alignment: .center, spacing: 8) {
                    if let title {
                        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    accessory.controlSize(.small)
                }
                .frame(minHeight: 18)
                .padding(.horizontal, 4)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        if row.id != rows.first?.id { Divider().padding(.leading, 12) }
                        row
                    }
                }
            }
            .background(PanelStyle.fill, in: RoundedRectangle(cornerRadius: PanelStyle.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PanelStyle.radius, style: .continuous).strokeBorder(PanelStyle.stroke))
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension Panel where Accessory == EmptyView {
    init(_ title: String? = nil, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, note: note, content: content) { EmptyView() }
    }
}

extension Panel {
    init(_ title: String? = nil, note: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.init(title: title, note: note, content: content, accessory: accessory)
    }
}

enum PanelStyle {
    static let radius: CGFloat = 10
    /// Lighter than the window in both appearances, like grouped content.
    static let fill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.05) : NSColor.white.withAlphaComponent(0.75)
    })
    static let stroke = Color(nsColor: .separatorColor).opacity(0.6)
    static let rowPadding = EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 10)
}

/// A panel row: one line, compact padding.
struct PanelRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .frame(minHeight: 22)
            .padding(PanelStyle.rowPadding)
            .contentShape(Rectangle())
    }
}

/// A label on the leading side and a value or control on the trailing side.
struct SettingRow<Content: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder var content: Content

    var body: some View {
        PanelRow {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            content
        }
    }
}

/// A value to read and copy (a host, a port, a path, a command): the label,
/// the value in monospace, and a copy button.
struct ValueRow: View {
    let label: String
    let value: String
    var revealsFile = false

    var body: some View {
        PanelRow {
            Text(label).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
            Spacer(minLength: 8)
            if revealsFile {
                IconButton(title: "Show in Finder", symbol: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: value)])
                }
            }
            CopyButton(value: value, label: label)
        }
        .contextMenu {
            Button("Copy \(label)") { Pasteboard.copy(value) }
        }
    }
}

/// An icon-only button for rows and bars; the title is its tooltip and
/// accessibility label.
struct IconButton: View {
    let title: String
    let symbol: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol).frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A service state at a glance.
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
    }
}

/// A one-line notice above the panels: what needs doing and the action.
struct Banner<Actions: View>: View {
    let symbol: String
    let title: String
    var detail: String?
    var tint: Color = .orange
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.body.weight(.semibold)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 8)
            actions.controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: PanelStyle.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PanelStyle.radius, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }
}

extension Banner where Actions == EmptyView {
    init(symbol: String, title: String, detail: String? = nil, tint: Color = .orange) {
        self.init(symbol: symbol, title: title, detail: detail, tint: tint) { EmptyView() }
    }
}

/// A small capsule for a short fact: "PHP 8.5", "Legacy", "Default".
struct Tag: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

enum Pasteboard {
    static func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
