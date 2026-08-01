import AppKit
import SceneKit
import simd

/// Fallback display size in meters (14" MBP), used only when the display metrics are unavailable.
let SCREEN_W = 0.302
let SCREEN_H = 0.196
/// Bottom edge of the display area down to the physical hinge axis.
let HINGE_GAP = 0.010
/// Standing eye height above the pavement. Brunelleschi's stance, and the reason the horizon lands
/// where it does.
let EYE_HEIGHT = 1.60
let NEAR = 0.8
let FAR = 400.0

func glassRect(viewSize: CGSize, on screen: NSScreen?, screenFrame: NSRect?) -> GlassRect {
    guard let screen,
          let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else { return GlassRect() }
    let sizeMM = CGDisplayScreenSize(CGDirectDisplayID(num.uint32Value))
    guard sizeMM.width > 1, viewSize.width > 1, viewSize.height > 1 else { return GlassRect() }
    let s = screen.frame
    let mx = Double(sizeMM.width / s.width) / 1000   // meters per point
    let my = Double(sizeMM.height / s.height) / 1000
    let f = screenFrame ?? NSRect(x: s.midX - viewSize.width / 2, y: s.minY + 40,
                                  width: viewSize.width, height: viewSize.height)
    return GlassRect(offR: Double(f.midX - s.midX) * mx,
                     offU: Double(f.midY - s.minY) * my + HINGE_GAP,
                     w: Double(f.width) * mx, h: Double(f.height) * my)
}

/// Transparent layer over the render, carrying the drawn construction. Kept a plain view rather
/// than a SpriteKit overlay so a still can run the identical drawing code into a bitmap.
final class OverlayView: NSView {
    var construction = Construction(principal: SIMD2(0, 0))

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawConstruction(construction, in: ctx, size: bounds.size)
    }
}

final class TavolettaView: SCNView, SCNSceneRendererDelegate {
    var client: PoseClient!
    var cameraNode: SCNNode!
    var rig: Apparatus!
    var overlay: OverlayView!

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "r":
            rig.reseat()
            client.recenter()
        case "l": rig.showLines.toggle()
        case "]": rig.nudgeEye(+0.02)
        case "[": rig.nudgeEye(-0.02)
        case "q": NSApp.terminate(nil)
        default: super.keyDown(with: event)
        }
    }

    // MARK: - where the window physically is

    private var cachedGlass = GlassRect()
    private let glassLock = NSLock()

    private func currentGlass() -> GlassRect {
        glassLock.lock()
        defer { glassLock.unlock() }
        return cachedGlass
    }

    override func layout() {
        super.layout()
        refreshGlassRect()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let win = window else { return }
        let c = NotificationCenter.default
        for name: NSNotification.Name in [NSWindow.didMoveNotification,
                                          NSWindow.didResizeNotification,
                                          NSWindow.didChangeScreenNotification] {
            c.addObserver(forName: name, object: win, queue: .main) { [weak self] _ in
                self?.refreshGlassRect()
            }
        }
        refreshGlassRect()
    }

    /// Main thread only.
    private func refreshGlassRect() {
        let screen = window?.screen ?? NSScreen.main
        let frame = window.map { $0.convertToScreen(convert(bounds, to: nil)) }
        let r = glassRect(viewSize: bounds.size, on: screen, screenFrame: frame)
        glassLock.lock()
        cachedGlass = r
        glassLock.unlock()
    }

    // MARK: - per frame

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let (q, lid, connected, hasPose) = client.latest()
        let frame = rig.update(baseQ: q, lid: lid, hasPose: hasPose, connected: connected,
                               glass: currentGlass())
        frame.apply(to: cameraNode)
        DispatchQueue.main.async { [weak self] in
            self?.overlay.construction = frame.construction
            self?.overlay.needsDisplay = true
        }
    }
}
