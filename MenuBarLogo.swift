import AppKit

/// The Q / quota-ring brand mark, drawn for the menu bar rather than shrinking the app tile.
enum QuotaBarLogo {
    static let menuBar: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let ring = NSBezierPath()
            ring.lineWidth = 2.6
            ring.lineCapStyle = .round
            ring.appendArc(withCenter: NSPoint(x: 8.5, y: 9.5), radius: 6,
                           startAngle: 65, endAngle: 385, clockwise: false)
            ring.stroke()
            let tail = NSBezierPath()
            tail.lineWidth = 2.8
            tail.lineCapStyle = .round
            tail.move(to: NSPoint(x: 10.3, y: 7.1))
            tail.line(to: NSPoint(x: 15.2, y: 2.2))
            tail.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "QuotaBar"
        return image
    }()
}
