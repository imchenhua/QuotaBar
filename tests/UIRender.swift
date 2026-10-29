import AppKit
import SwiftUI
import Foundation

@main struct UIRender {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = QuotaStore(preview: true)
        precondition(store.activeAccount?.name == "Lab", "Current account must be identified independently of saved login state")
        precondition(store.menuBarText.contains("Lab"), "Menu bar must identify the displayed account")
        let height: CGFloat = CommandLine.arguments.contains("--short") ? 420 : 720
        let dark = CommandLine.arguments.contains("--dark")
        let view = ContentView(store: store, isPreview: true,
                               initialSettings: CommandLine.arguments.contains("--settings"), viewportHeight: height)
            .preferredColorScheme(dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        var size = host.fittingSize
        print("intrinsic-size \(size.width) x \(size.height)")
        precondition(abs(size.width - 360) < 1 && size.height <= height && size.height >= 160,
                     "Panel must retain a bounded, nonzero viewport")
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        for _ in 0..<3 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        size = host.fittingSize
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<2 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        precondition(size.height <= height && size.height >= 160, "Content-measured size must stay within screen limits")
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try data.write(to: output.appendingPathComponent("panel.png"))
        // Recreate constrained hosts to model repeated popover presentation.
        for _ in 0..<3 {
            let reopened = NSHostingView(rootView: view)
            reopened.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
            precondition(abs(reopened.fittingSize.width - 360) < 1
                         && reopened.fittingSize.height <= height && reopened.fittingSize.height >= 160,
                         "Recreated panel must not collapse after a small layout proposal")
        }
        func findScroll(_ node: NSView) -> NSScrollView? {
            if let scroll = node as? NSScrollView { return scroll }
            for child in node.subviews { if let scroll = findScroll(child) { return scroll } }
            return nil
        }
        var documentHeight: CGFloat = 0
        var visibleHeight: CGFloat = 0
        if let scroll = findScroll(host), let document = scroll.documentView {
            documentHeight = document.bounds.height
            visibleHeight = scroll.contentView.bounds.height
            if !CommandLine.arguments.contains("--short") && !CommandLine.arguments.contains("--settings") {
                precondition(abs(documentHeight - visibleHeight) < 2,
                             "A panel that fits on screen must not retain an empty scroll viewport below its content")
            }
            let bottom = max(0, documentHeight - visibleHeight)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? bottom : 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            for _ in 0..<2 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            host.layoutSubtreeIfNeeded()
            if let bottomBitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bottomBitmap)
                try bottomBitmap.representation(using: .png, properties: [:])?
                    .write(to: output.appendingPathComponent("panel-scrolled.png"))
            }
        }
        let report: [String: Any] = ["width":size.width,"height":size.height,"isOffscreenFixture":true,
            "documentHeight":documentHeight,"scrollViewportHeight":visibleHeight,
            "recreatedHostChecks":3]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]).write(to: output.appendingPathComponent("layout.json"))
    }
}
