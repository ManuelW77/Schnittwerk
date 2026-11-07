// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Mouse and trackpad navigation on the mat:
//  • pinch (trackpad) or ⌘/⌥ + scroll wheel: zoom around the pointer
//  • hold space and drag, or drag with the middle mouse button: move the mat
// Plain scrolling is handled by the scroll view itself.

import AppKit
import SwiftUI

struct MatNavigator: NSViewRepresentable {
    @Binding var zoom: CGFloat
    let range: ClosedRange<CGFloat>

    static let zoomRange: ClosedRange<CGFloat> = 0.25...8
    /// Top left corner of the mat content inside the scroll view
    /// (padding around the canvas + canvas margin), in points.
    static let contentInset: CGFloat = 8 + MatCanvasView.margin

    /// True while the hand (space held or panning) is active, so the
    /// canvas does not overwrite the hand cursor.
    @MainActor static var handActive = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.zoom = $zoom
        context.coordinator.range = range
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.zoom = $zoom
        context.coordinator.range = range
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var zoom: Binding<CGFloat>?
        var range: ClosedRange<CGFloat> = MatNavigator.zoomRange
        private var monitor: Any?
        private var spaceHeld = false
        private var panning = false

        func install() {
            let mask: NSEvent.EventTypeMask = [.scrollWheel, .magnify, .otherMouseDown, .otherMouseDragged,
                                               .otherMouseUp, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                               .keyDown, .keyUp]
            monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) ?? event }
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            setHand(false)
        }

        private var scrollView: NSScrollView? { view?.enclosingScrollView }

        /// True if the event happened in our window over the visible mat.
        private func isOverMat(_ event: NSEvent) -> Bool {
            guard let scrollView, let window = view?.window, event.window === window else { return false }
            let p = scrollView.convert(event.locationInWindow, from: nil)
            return scrollView.bounds.contains(p)
        }

        /// Space must not be taken from text fields.
        private var isTyping: Bool {
            view?.window?.firstResponder is NSText
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            switch event.type {
            case .scrollWheel:
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard mods.contains(.command) || mods.contains(.option), isOverMat(event) else { return event }
                let delta = event.scrollingDeltaY
                guard delta != 0 else { return nil }
                let step: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
                zoom(by: exp(delta * step), at: event)
                return nil
            case .magnify:
                guard isOverMat(event) else { return event }
                zoom(by: 1 + event.magnification, at: event)
                return nil
            case .otherMouseDown:
                guard isOverMat(event) else { return event }
                panning = true
                setHand(true, grabbing: true)
                return nil
            case .otherMouseDragged:
                guard panning else { return event }
                pan(dx: event.deltaX, dy: event.deltaY)
                return nil
            case .otherMouseUp:
                guard panning else { return event }
                panning = false
                setHand(false)
                return nil
            case .keyDown:
                guard event.keyCode == 49, view?.window?.isKeyWindow == true, event.window === view?.window,
                      !isTyping, event.modifierFlags.intersection([.command, .control, .option]).isEmpty
                else { return event }
                if !spaceHeld {
                    spaceHeld = true
                    setHand(true)
                }
                return nil
            case .keyUp:
                guard event.keyCode == 49, spaceHeld else { return event }
                spaceHeld = false
                if !panning { setHand(false) }
                return nil
            case .leftMouseDown:
                guard spaceHeld, isOverMat(event) else { return event }
                panning = true
                setHand(true, grabbing: true)
                return nil
            case .leftMouseDragged:
                guard panning else { return event }
                pan(dx: event.deltaX, dy: event.deltaY)
                return nil
            case .leftMouseUp:
                guard panning else { return event }
                panning = false
                setHand(spaceHeld)
                return nil
            default:
                return event
            }
        }

        private func setHand(_ on: Bool, grabbing: Bool = false) {
            MatNavigator.handActive = on
            if on { (grabbing ? NSCursor.closedHand : NSCursor.openHand).set() } else { NSCursor.arrow.set() }
        }

        /// Moves the visible part of the mat with the pointer.
        private func pan(dx: CGFloat, dy: CGFloat) {
            guard let scrollView else { return }
            let clip = scrollView.contentView
            var origin = clip.bounds.origin
            origin.x -= dx
            origin.y += clip.isFlipped ? -dy : dy
            scroll(clip, to: origin)
        }

        /// Zooms so the point under the pointer stays where it is.
        private func zoom(by factor: CGFloat, at event: NSEvent) {
            guard let zoom, let scrollView, factor.isFinite, factor > 0 else { return }
            let old = zoom.wrappedValue
            let new = min(max(old * factor, range.lowerBound), range.upperBound)
            guard abs(new - old) > 0.0001 else { return }
            let clip = scrollView.contentView
            let p = clip.convert(event.locationInWindow, from: nil) // document coordinates
            let origin = clip.bounds.origin
            let offset = CGPoint(x: p.x - origin.x, y: p.y - origin.y)
            zoom.wrappedValue = new

            let ratio = new / old
            let inset = MatNavigator.contentInset
            let flipped = clip.isFlipped
            let docHeightBefore = scrollView.documentView?.frame.height ?? 0
            // After SwiftUI laid out the new size, keep the point under the pointer
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.scrollView else { return }
                scrollView.documentView?.layoutSubtreeIfNeeded()
                let clip = scrollView.contentView
                let x = inset + (p.x - inset) * ratio
                let y: CGFloat
                if flipped {
                    y = inset + (p.y - inset) * ratio
                } else {
                    // y measured from the top of the document
                    let docHeightAfter = scrollView.documentView?.frame.height ?? docHeightBefore
                    let top = docHeightBefore - p.y
                    y = docHeightAfter - (inset + (top - inset) * ratio)
                }
                self.scroll(clip, to: CGPoint(x: x - offset.x, y: y - offset.y))
            }
        }

        private func scroll(_ clip: NSClipView, to origin: CGPoint) {
            let rect = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
            clip.scroll(to: rect.origin)
            clip.enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }
}
