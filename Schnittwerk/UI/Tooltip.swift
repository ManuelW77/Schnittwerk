// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Own tooltips instead of the system ones: they open after a short
// moment (and at once while moving from one control to the next), show
// the keyboard shortcut apart from the text, and look like the rest of
// the app. They live in a small floating panel, so nothing clips them.

import AppKit
import SwiftUI

/// What a tooltip shows.
struct TipContent: Equatable {
    var title: String?
    var text: String
    var shortcut: String?

    /// Splits a trailing shortcut such as "Duplicate (⌘D)" or
    /// "Select and move objects (V)" off the text.
    init(title: String? = nil, text: String, shortcut: String? = nil) {
        self.title = title
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var key = shortcut
        if key == nil, body.hasSuffix(")"), let open = body.lastIndex(of: "(") {
            let inner = String(body[body.index(after: open)..<body.index(before: body.endIndex)])
            let modifiers = CharacterSet(charactersIn: "⌘⇧⌥⌃⌫↩︎←→↑↓")
            let looksLikeKey = inner.count <= 6
                && (inner.unicodeScalars.contains { modifiers.contains($0) } || (inner.count == 1 && inner.uppercased() == inner))
            if looksLikeKey {
                key = inner
                body = body[..<open].trimmingCharacters(in: .whitespaces)
            }
        }
        self.text = body
        self.shortcut = key
    }
}

private struct TipView: View {
    let content: TipContent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = content.title {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: title).font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                    if let key = content.shortcut { KeyCap(key) }
                }
                if !content.text.isEmpty {
                    Text(verbatim: content.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: content.text).font(.callout)
                    if let key = content.shortcut {
                        Spacer(minLength: 0)
                        KeyCap(key)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 300, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .padding(1)
    }
}

/// A keyboard key, e.g. ⌘D.
private struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(verbatim: key)
            .font(.caption.weight(.medium).monospaced())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundStyle(.secondary)
    }
}

@MainActor
final class TipCenter {
    static let shared = TipCenter()

    /// Wait before the first tooltip opens.
    static let delay: TimeInterval = 0.35
    /// While a tooltip was open this recently, the next one opens at once.
    static let warmPeriod: TimeInterval = 0.8

    private var panel: NSPanel?
    private var host: NSHostingView<AnyView>?
    private var pending: DispatchWorkItem?
    private var owner: UUID?
    private var lastHidden = Date.distantPast
    private var monitor: Any?

    private init() {}

    func enter(_ id: UUID, _ content: TipContent) {
        installMonitor()
        pending?.cancel()
        owner = id
        let warm = panel?.isVisible == true || Date().timeIntervalSince(lastHidden) < Self.warmPeriod
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.owner == id else { return }
            self.show(content)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (warm ? 0.05 : Self.delay), execute: work)
    }

    func leave(_ id: UUID) {
        guard owner == id else { return }
        hide()
    }

    func hide() {
        pending?.cancel()
        pending = nil
        owner = nil
        if panel?.isVisible == true {
            panel?.orderOut(nil)
            lastHidden = Date()
        }
    }

    private func show(_ content: TipContent) {
        let panel = self.panel ?? makePanel()
        let view = AnyView(TipView(content: content))
        if let host { host.rootView = view } else {
            let h = NSHostingView(rootView: view)
            panel.contentView = h
            host = h
        }
        guard let host else { return }
        let size = host.fittingSize
        // Below right of the pointer, kept on the screen
        let mouse = NSEvent.mouseLocation
        var origin = CGPoint(x: mouse.x + 10, y: mouse.y - size.height - 22)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX + 4), f.maxX - size.width - 4)
            if origin.y < f.minY + 4 { origin.y = mouse.y + 16 } // no room below: above the pointer
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        p.isReleasedWhenClosed = false
        panel = p
        return p
    }

    /// Clicks, keys and scrolling close the tooltip at once.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                              .keyDown, .scrollWheel]) { event in
            TipCenter.shared.hide()
            return event
        }
    }
}

private struct TipModifier: ViewModifier {
    let content: TipContent
    @State private var id = UUID()

    func body(content view: Content) -> some View {
        view
            .onHover { inside in
                if inside { TipCenter.shared.enter(id, content) } else { TipCenter.shared.leave(id) }
            }
            .onDisappear { TipCenter.shared.leave(id) }
            .accessibilityHint(Text(verbatim: content.text))
    }
}

extension View {
    /// Tooltip with a localised text; a trailing "(⌘D)" becomes the shortcut.
    func tip(_ text: String.LocalizationValue) -> some View {
        modifier(TipModifier(content: TipContent(text: String(localized: text))))
    }

    /// Tooltip with an already localised text.
    @_disfavoredOverload
    func tip(_ text: String) -> some View {
        modifier(TipModifier(content: TipContent(text: text)))
    }

    func tip(_ content: TipContent) -> some View {
        modifier(TipModifier(content: content))
    }

    /// Tooltip with a bold title (e.g. the name of an icon button),
    /// an explanation and an optional shortcut.
    func tip(title: String.LocalizationValue, _ text: String.LocalizationValue? = nil, shortcut: String? = nil) -> some View {
        modifier(TipModifier(content: TipContent(title: String(localized: title),
                                                 text: text.map { String(localized: $0) } ?? "",
                                                 shortcut: shortcut)))
    }
}
