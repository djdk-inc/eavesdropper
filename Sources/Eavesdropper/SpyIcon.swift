import AppKit

/// The menu bar icon: a small round spy in a fedora, glancing sideways.
/// A template image, so macOS tints it to match the menu bar in light and dark mode.
/// `listening` adds a dot in the corner while a call is being recorded.
func spyIcon(listening: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        drawSpy(listening: listening)
        return true
    }
    image.isTemplate = true
    return image
}

/// Draws in an 18×18 space, origin bottom-left.
func drawSpy(listening: Bool) {
    NSColor.black.setFill()
    let context = NSGraphicsContext.current

    // The figure sits a little inside the 18 pt box.
    context?.saveGraphicsState()
    let shrink = NSAffineTransform()
    shrink.translateX(by: 9, yBy: 9)
    shrink.scale(by: 0.88)
    shrink.translateX(by: -9, yBy: -9)
    shrink.concat()

    // Little coat collar peeking out under the head.
    let collar = NSBezierPath()
    collar.move(to: NSPoint(x: 4.4, y: 0))
    collar.line(to: NSPoint(x: 13.6, y: 0))
    collar.line(to: NSPoint(x: 12.8, y: 2.8))
    collar.line(to: NSPoint(x: 9, y: 1.0))
    collar.line(to: NSPoint(x: 5.2, y: 2.8))
    collar.close()
    collar.fill()

    // Big round head.
    NSBezierPath(ovalIn: NSRect(x: 4.0, y: 1.6, width: 10.0, height: 9.8)).fill()

    // Fedora: soft pill brim and a rounded crown.
    NSBezierPath(roundedRect: NSRect(x: 2.6, y: 10.0, width: 12.8, height: 1.5), xRadius: 0.75, yRadius: 0.75).fill()
    NSBezierPath(roundedRect: NSRect(x: 5.2, y: 10.6, width: 7.6, height: 4.6), xRadius: 2.0, yRadius: 2.0).fill()

    // Big eyes (cut out of the head).
    context?.compositingOperation = .clear
    NSBezierPath(ovalIn: NSRect(x: 5.2, y: 4.4, width: 3.6, height: 4.2)).fill()
    NSBezierPath(ovalIn: NSRect(x: 9.2, y: 4.4, width: 3.6, height: 4.2)).fill()
    context?.compositingOperation = .sourceOver

    // Pupils glancing sideways, each with a tiny highlight.
    NSBezierPath(ovalIn: NSRect(x: 6.5, y: 5.0, width: 2.1, height: 2.5)).fill()
    NSBezierPath(ovalIn: NSRect(x: 10.5, y: 5.0, width: 2.1, height: 2.5)).fill()
    context?.compositingOperation = .clear
    NSBezierPath(ovalIn: NSRect(x: 7.5, y: 6.5, width: 0.7, height: 0.7)).fill()
    NSBezierPath(ovalIn: NSRect(x: 11.5, y: 6.5, width: 0.7, height: 0.7)).fill()
    context?.compositingOperation = .sourceOver
    context?.restoreGraphicsState()

    if listening {
        context?.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: 11.8, y: 11.8, width: 7.2, height: 7.2)).fill()
        context?.compositingOperation = .sourceOver
        NSBezierPath(ovalIn: NSRect(x: 12.8, y: 12.8, width: 5.2, height: 5.2)).fill()
    }
}
