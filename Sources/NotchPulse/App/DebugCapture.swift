import AppKit
import CoreGraphics

/// Dev-only: grab a PNG of the notch region from inside the process.
///
///   --capture=/path/out.png      write a screenshot, then quit
///   --capture-delay=2.5          seconds to wait first (default 2.5)
///   --capture-rect=x,y,w,h       region in points, top-left origin (default: around the island)
///
/// Uses CGWindowListCreateImage looked up at runtime (it's obsoleted in the Swift SDK
/// overlay but still exported). A process may always capture its own windows, so this works
/// without Screen Recording permission (other apps' windows are simply omitted).
@MainActor
enum DebugCapture {
    private typealias CreateImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func scheduleIfRequested(arguments: [String] = CommandLine.arguments, geometry: @escaping () -> NotchGeometry) {
        func value(_ key: String) -> String? {
            arguments.first(where: { $0.hasPrefix(key + "=") }).map { String($0.dropFirst(key.count + 1)) }
        }
        guard let path = value("--capture") else { return }
        let delay = value("--capture-delay").flatMap(Double.init) ?? 2.5

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let rect: CGRect
            if let raw = value("--capture-rect") {
                let n = raw.split(separator: ",").compactMap { Double($0) }
                rect = n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : .null
            } else {
                // Region around the expanded island, in CG (top-left origin) coordinates.
                let g = geometry()
                let w = g.expandedSize.width + 80
                let h = g.topInset + g.expandedSize.height + 50
                let screenTop = (NSScreen.screens.first?.frame.maxY ?? g.screenFrame.maxY) - g.screenFrame.maxY
                rect = CGRect(x: g.centerX - w / 2, y: screenTop, width: w, height: h)
            }
            if let image = createImage(rect) {
                let rep = NSBitmapImageRep(cgImage: image)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                    print("NotchPulse: captured \(image.width)x\(image.height) → \(path)")
                }
            } else {
                print("NotchPulse: capture failed")
            }
            NSApp.terminate(nil)
        }
    }

    private static func createImage(_ rect: CGRect) -> CGImage? {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: CreateImageFn.self)
        // kCGWindowListOptionOnScreenOnly = 1, kCGWindowImageDefault = 0
        return fn(rect, 1, 0, 0)?.takeRetainedValue()
    }
}
