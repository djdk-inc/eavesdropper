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

    // Coat collar, turned up.
    let collar = NSBezierPath()
    collar.move(to: NSPoint(x: 3.2, y: 0))
    collar.line(to: NSPoint(x: 14.8, y: 0))
    collar.line(to: NSPoint(x: 13.4, y: 3.4))
    collar.line(to: NSPoint(x: 9, y: 1.2))
    collar.line(to: NSPoint(x: 4.6, y: 3.4))
    collar.close()
    collar.fill()

    // Round head.
    NSBezierPath(ovalIn: NSRect(x: 4.3, y: 2.3, width: 9.4, height: 9.0)).fill()

    // Little pointy nose, peeking right.
    let nose = NSBezierPath()
    nose.move(to: NSPoint(x: 12.6, y: 6.6))
    nose.curve(to: NSPoint(x: 16.2, y: 5.0), controlPoint1: NSPoint(x: 14.2, y: 6.5), controlPoint2: NSPoint(x: 15.6, y: 5.8))
    nose.curve(to: NSPoint(x: 12.4, y: 4.4), controlPoint1: NSPoint(x: 15.0, y: 4.5), controlPoint2: NSPoint(x: 13.6, y: 4.3))
    nose.close()
    nose.fill()

    // Fedora: brim and crown.
    NSBezierPath(roundedRect: NSRect(x: 1.8, y: 10.2, width: 14.4, height: 1.7), xRadius: 0.85, yRadius: 0.85).fill()
    let crown = NSBezierPath()
    crown.move(to: NSPoint(x: 5.0, y: 11.5))
    crown.line(to: NSPoint(x: 5.4, y: 15.2))
    crown.curve(to: NSPoint(x: 9, y: 16.0), controlPoint1: NSPoint(x: 6.6, y: 16.4), controlPoint2: NSPoint(x: 7.8, y: 16.0))
    crown.curve(to: NSPoint(x: 12.6, y: 15.2), controlPoint1: NSPoint(x: 10.2, y: 16.0), controlPoint2: NSPoint(x: 11.4, y: 16.4))
    crown.line(to: NSPoint(x: 13.0, y: 11.5))
    crown.close()
    crown.fill()

    // Cut-outs: hat band and big eyes.
    let context = NSGraphicsContext.current
    context?.compositingOperation = .clear
    NSRect(x: 5.0, y: 12.2, width: 8.0, height: 0.8).fill(using: .clear)
    NSBezierPath(ovalIn: NSRect(x: 5.4, y: 5.6, width: 3.4, height: 3.6)).fill()
    NSBezierPath(ovalIn: NSRect(x: 9.0, y: 5.6, width: 3.4, height: 3.6)).fill()
    context?.compositingOperation = .sourceOver

    // Pupils, glancing sideways.
    NSBezierPath(ovalIn: NSRect(x: 7.1, y: 6.4, width: 1.5, height: 1.7)).fill()
    NSBezierPath(ovalIn: NSRect(x: 10.7, y: 6.4, width: 1.5, height: 1.7)).fill()

    if listening {
        context?.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: 12.8, y: 12.6, width: 6.0, height: 6.0)).fill()
        context?.compositingOperation = .sourceOver
        NSBezierPath(ovalIn: NSRect(x: 13.8, y: 13.6, width: 4.0, height: 4.0)).fill()
    }
}
