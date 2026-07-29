// Anamorphic magic window (the Holbein mode): the scene is fixed in the room, the viewer's eye is
// fixed in front of the laptop, and the physical screen is a pane of glass whose pose comes from
// wabed (base attitude ⊕ lid angle). Each frame we rebuild an off-axis frustum through the glass
// (Kooima, "Generalized Perspective Projection"), so tilting the screen or laptop shears the image
// exactly the way a real window would — The Ambassadors' skull, continuously.
// Keys: m cycle mode (window / screen-rot / base-rot) · r recenter · [ ] eye distance · q quit.
import AppKit
import Foundation
import SceneKit
import simd

// Fallback glass size, meters (16" MBP display) — used only if display metrics are unavailable.
let SCREEN_W = 0.344
let SCREEN_H = 0.222
// Distance from the bottom edge of the display area down to the physical hinge axis.
let HINGE_GAP = 0.010

// MARK: - pose client (unix socket, newline JSON)

final class PoseClient {
    private(set) var q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)  // base -> world
    private(set) var lidDeg = 110.0
    private var fd: Int32 = -1
    private let path: String
    private let lock = NSLock()

    init(path: String) {
        self.path = path
        Thread.detachNewThread { [weak self] in self?.readLoop() }
    }

    func latest() -> (q: simd_quatd, lid: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (q, lidDeg)
    }

    func recenter() {
        if fd >= 0 { _ = "recenter\n".withCString { send(fd, $0, 9, 0) } }
    }

    private func readLoop() {
        struct Pose: Decodable {
            let q: [Double]
            let lid: Double
        }
        while true {
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                path.utf8CString.withUnsafeBufferPointer { src in
                    raw.copyBytes(from: UnsafeRawBufferPointer(start: src.baseAddress, count: min(src.count, raw.count - 1)))
                }
            }
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if ok != 0 {
                close(s)
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            fd = s
            var buf = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(s, &chunk, chunk.count)
                if n <= 0 { break }
                buf.append(contentsOf: chunk[0..<n])
                while let nl = buf.firstIndex(of: 0x0A) {
                    let line = buf.prefix(upTo: nl)
                    buf.removeSubrange(...nl)
                    guard let p = try? JSONDecoder().decode(Pose.self, from: line), p.q.count == 4 else { continue }
                    lock.lock()
                    q = simd_quatd(ix: p.q[1], iy: p.q[2], iz: p.q[3], r: p.q[0])
                    if p.lid >= 0 { lidDeg = p.lid }
                    lock.unlock()
                }
            }
            close(s)
            fd = -1
        }
    }
}

// MARK: - scene, built in the wabe world frame: X right, Y through the glass into the scene, Z up.
// The glass is centered at the origin; everything lives at y > 0 (behind the window).

func buildScene() -> SCNScene {
    let scene = SCNScene()
    scene.background.contents = NSColor.black
    var rng = SystemRandomNumberGenerator()

    // Checker ground plane (thin box so orientation is explicit in our z-up frame).
    let tile = 64
    let img = NSImage(size: NSSize(width: tile * 2, height: tile * 2), flipped: false) { rect in
        NSColor(white: 0.10, alpha: 1).setFill()
        rect.fill()
        NSColor(white: 0.20, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: tile, height: tile).fill()
        NSRect(x: tile, y: tile, width: tile, height: tile).fill()
        return true
    }
    let ground = SCNBox(width: 30, height: 30, length: 0.01, chamferRadius: 0)
    ground.firstMaterial?.diffuse.contents = img
    ground.firstMaterial?.diffuse.wrapS = .repeat
    ground.firstMaterial?.diffuse.wrapT = .repeat
    ground.firstMaterial?.diffuse.contentsTransform = SCNMatrix4MakeScale(60, 60, 1)
    let groundNode = SCNNode(geometry: ground)
    groundNode.simdPosition = SIMD3(0, 15, -0.30)  // z-up frame: box length axis is z
    scene.rootNode.addChildNode(groundNode)

    // A colonnade of columns receding into the scene — strong anamorphic subject: straight
    // verticals shear visibly the instant the projection is wrong.
    for i in 0..<8 {
        for side in [-1.0, 1.0] {
            let col = SCNCylinder(radius: 0.035, height: 0.75)
            col.firstMaterial?.diffuse.contents = NSColor(white: 0.75, alpha: 1)
            let n = SCNNode(geometry: col)
            // SCNCylinder's axis is local y; rotate so it stands along world z.
            n.simdOrientation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
            n.simdPosition = SIMD3(Float(side * 0.28), Float(0.25 + Double(i) * 0.45), 0.075)
            scene.rootNode.addChildNode(n)
        }
    }

    // Floating cubes at staggered depths.
    let palette: [NSColor] = [.systemOrange, .systemTeal, .systemPink, .systemGreen, .systemYellow]
    for i in 0..<28 {
        let size = CGFloat.random(in: 0.03...0.12, using: &rng)
        let box = SCNBox(width: size, height: size, length: size, chamferRadius: size * 0.1)
        box.firstMaterial?.diffuse.contents = palette[i % palette.count]
        box.firstMaterial?.emission.contents = palette[i % palette.count].withAlphaComponent(0.2)
        let node = SCNNode(geometry: box)
        node.simdPosition = SIMD3(
            Float.random(in: -0.8...0.8, using: &rng),
            Float.random(in: 0.15...2.8, using: &rng),
            Float.random(in: -0.25...0.55, using: &rng))
        let spin = CABasicAnimation(keyPath: "rotation")
        spin.toValue = NSValue(scnVector4: SCNVector4(0, 0, 1, CGFloat.pi * 2))
        spin.duration = Double.random(in: 15...45, using: &rng)
        spin.repeatCount = .infinity
        node.addAnimation(spin, forKey: "spin")
        scene.rootNode.addChildNode(node)
    }

    // One near object floating right at the glass — pokes "through" convincingly.
    let orb = SCNSphere(radius: 0.025)
    orb.firstMaterial?.diffuse.contents = NSColor.systemRed
    orb.firstMaterial?.emission.contents = NSColor.systemRed.withAlphaComponent(0.4)
    let orbNode = SCNNode(geometry: orb)
    orbNode.simdPosition = SIMD3(0.1, 0.08, 0.02)
    scene.rootNode.addChildNode(orbNode)

    // Distant stars.
    for _ in 0..<250 {
        let s = SCNSphere(radius: 0.05)
        s.firstMaterial?.emission.contents = NSColor.white
        let n = SCNNode(geometry: s)
        let theta = Double.random(in: -1.2...1.2, using: &rng)
        let phi = Double.random(in: -0.15...0.9, using: &rng)
        let r = 25.0
        n.simdPosition = SIMD3(
            Float(r * sin(theta) * cos(phi)), Float(r * cos(theta) * cos(phi)), Float(r * sin(phi)))
        scene.rootNode.addChildNode(n)
    }

    let ambient = SCNNode()
    ambient.light = SCNLight()
    ambient.light!.type = .ambient
    ambient.light!.intensity = 350
    scene.rootNode.addChildNode(ambient)

    let sun = SCNNode()
    sun.light = SCNLight()
    sun.light!.type = .directional
    sun.light!.intensity = 650
    sun.simdOrientation = simd_quatf(angle: -1.1, axis: simd_normalize(SIMD3(1, 0.3, 0)))
    scene.rootNode.addChildNode(sun)

    return scene
}

// MARK: - view

enum Mode: String {
    case window = "anamorphic window"
    case screenRot = "screen-rotation"
    case baseRot = "base-rotation"
}

final class MagicWindowView: SCNView, SCNSceneRendererDelegate {
    var client: PoseClient!
    var cameraNode: SCNNode!
    var mode = Mode.screenRot
    var eyeDist = 0.55  // meters from glass center to the viewer's eye at recenter
    private var refQ: simd_quatd?  // screen pose at recenter; eye is pinned along its normal
    private var smoothedEye: SIMD3<Double>?

    override var acceptsFirstResponder: Bool { true }

    private func retitle() {
        window?.title = "wabe — \(mode.rawValue)   (m mode · r recenter · [ ] eye dist · q quit)"
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "r":
            refQ = nil
            smoothedEye = nil
            client.recenter()
        case "m":
            mode = mode == .window ? .screenRot : (mode == .screenRot ? .baseRot : .window)
            refQ = nil
            smoothedEye = nil
            retitle()
        case "]": eyeDist = min(1.2, eyeDist + 0.05)
        case "[": eyeDist = max(0.25, eyeDist - 0.05)
        case "q": NSApp.terminate(nil)
        default: super.keyDown(with: event)
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let (baseQ, lid) = client.latest()
        // Screen pose: base ⊕ hinge. Screen-local axes: x right along the hinge, z up the glass,
        // -y the outward normal (toward the viewer) when everything is at identity.
        let hinge = simd_quatd(angle: (lid - 90) * .pi / 180, axis: SIMD3(1, 0, 0))
        let screenQ = baseQ * hinge

        switch mode {
        case .window:
            renderWindow(screenQ: screenQ)
        case .screenRot, .baseRot:
            renderRotation(q: mode == .screenRot ? screenQ : baseQ)
        }
    }

    // Map this view's rect to physical millimeters on the built-in display. Returns the view
    // center's offset from the hinge in screen-plane coordinates (right, up-glass) plus the view's
    // physical size — so the glass quad is the *window*, wherever it sits, whatever its size.
    private func viewRectOnGlass() -> (offR: Double, offU: Double, w: Double, h: Double)? {
        guard let win = window, let screen = win.screen ?? NSScreen.main,
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let sizeMM = CGDisplayScreenSize(CGDirectDisplayID(num.uint32Value))
        guard sizeMM.width > 1 else { return nil }
        let sFrame = screen.frame
        let vFrame = win.convertToScreen(convert(bounds, to: nil))
        let mmX = Double(sizeMM.width / sFrame.width) / 1000   // meters per point
        let mmY = Double(sizeMM.height / sFrame.height) / 1000
        let offR = Double(vFrame.midX - sFrame.midX) * mmX
        let offU = Double(vFrame.midY - sFrame.minY) * mmY + HINGE_GAP
        return (offR, offU, Double(vFrame.width) * mmX, Double(vFrame.height) * mmY)
    }

    // The Holbein path: eye fixed in the room, glass moving, off-axis frustum through it.
    // World origin = the hinge axis; the glass pivots about it like the physical lid does.
    private func renderWindow(screenQ: simd_quatd) {
        let rect = viewRectOnGlass() ?? (0, SCREEN_H / 2 + HINGE_GAP, SCREEN_W, SCREEN_H)
        let screenHalfH = (viewRectOnGlass() != nil && window?.screen != nil)
            ? Double(CGDisplayScreenSize(CGDirectDisplayID(
                ((window!.screen ?? NSScreen.main!).deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value)).height) / 2000
            : SCREEN_H / 2

        if refQ == nil { refQ = screenQ }
        // Eye pinned in the world: opposite the *screen center* (not the window) as of recenter.
        let refVu = refQ!.act(SIMD3<Double>(0, 0, 1))
        let refN = refQ!.act(SIMD3<Double>(0, -1, 0))
        let eye = refVu * (screenHalfH + HINGE_GAP) + refN * eyeDist

        // Glass basis in world, this frame.
        let vr = screenQ.act(SIMD3<Double>(1, 0, 0))   // right along hinge
        let vu = screenQ.act(SIMD3<Double>(0, 0, 1))   // up the glass
        let vn = screenQ.act(SIMD3<Double>(0, -1, 0))  // outward normal (toward viewer)

        // Glass corners: the window's physical rect, swung about the hinge at the origin.
        let center = vr * rect.offR + vu * rect.offU
        let pa = center - vr * (rect.w / 2) - vu * (rect.h / 2)  // lower-left
        let pb = center + vr * (rect.w / 2) - vu * (rect.h / 2)  // lower-right
        let pc = center - vr * (rect.w / 2) + vu * (rect.h / 2)  // upper-left

        // Kooima's generalized perspective projection.
        let va = pa - eye
        let vb = pb - eye
        let vc = pc - eye
        let d = max(0.05, -dot(va, vn))  // clamp: glass edge-on would degenerate the frustum
        let near = 0.03
        let far = 60.0
        let l = dot(vr, va) * near / d
        let r = dot(vr, vb) * near / d
        let b = dot(vu, va) * near / d
        let t = dot(vu, vc) * near / d

        var P = simd_double4x4(0)
        P[0][0] = 2 * near / (r - l)
        P[1][1] = 2 * near / (t - b)
        P[2][0] = (r + l) / (r - l)
        P[2][1] = (t + b) / (t - b)
        P[2][2] = -(far + near) / (far - near)
        P[2][3] = -1
        P[3][2] = -2 * far * near / (far - near)

        // Camera node carries the view transform: position at the eye, axes aligned to the glass.
        let R = simd_double3x3(columns: (vr, vu, vn))
        cameraNode.simdPosition = SIMD3<Float>(eye)
        let qd = simd_quatd(R)
        cameraNode.simdOrientation = simd_quatf(
            ix: Float(qd.imag.x), iy: Float(qd.imag.y), iz: Float(qd.imag.z), r: Float(qd.real))
        cameraNode.camera!.projectionTransform = SCNMatrix4(
            m11: CGFloat(P[0][0]), m12: CGFloat(P[0][1]), m13: CGFloat(P[0][2]), m14: CGFloat(P[0][3]),
            m21: CGFloat(P[1][0]), m22: CGFloat(P[1][1]), m23: CGFloat(P[1][2]), m24: CGFloat(P[1][3]),
            m31: CGFloat(P[2][0]), m32: CGFloat(P[2][1]), m33: CGFloat(P[2][2]), m34: CGFloat(P[2][3]),
            m41: CGFloat(P[3][0]), m42: CGFloat(P[3][1]), m43: CGFloat(P[3][2]), m44: CGFloat(P[3][3]))
    }

    // The old telescope modes, kept for comparison on the m key.
    private var rotSmoothed = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    private func renderRotation(q: simd_quatd) {
        if refQ == nil { refQ = q }
        let rel = refQ!.inverse * q
        let R = simd_quatd(simd_double3x3(
            SIMD3(1, 0, 0),
            SIMD3(0, 0, -1),
            SIMD3(0, 1, 0)))
        let camQ = R * rel * R.inverse
        rotSmoothed = simd_slerp(rotSmoothed, camQ, 0.35)
        // projectionTransform, once set, permanently overrides fieldOfView — so rotation modes
        // must set an explicit symmetric perspective matrix rather than expect a revert.
        let fov = 70.0 * .pi / 180
        let aspect = Double(bounds.width / max(1, bounds.height))
        let near = 0.03, far = 80.0
        let f = 1 / tan(fov / 2)
        var P = simd_double4x4(0)
        P[0][0] = f / aspect
        P[1][1] = f
        P[2][2] = -(far + near) / (far - near)
        P[2][3] = -1
        P[3][2] = -2 * far * near / (far - near)
        cameraNode.camera!.projectionTransform = SCNMatrix4(
            m11: CGFloat(P[0][0]), m12: 0, m13: 0, m14: 0,
            m21: 0, m22: CGFloat(P[1][1]), m23: 0, m24: 0,
            m31: 0, m32: 0, m33: CGFloat(P[2][2]), m34: CGFloat(P[2][3]),
            m41: 0, m42: 0, m43: CGFloat(P[3][2]), m44: 0)
        cameraNode.simdPosition = SIMD3(0, Float(-eyeDist), 0.05)
        // Base look direction +y (into the scene) in the rotation modes.
        let look = simd_quatd(angle: .pi / 2, axis: SIMD3(1, 0, 0))  // cam -z -> world +y, cam y -> world z
        let qd2 = simd_mul(look, rotSmoothed)
        cameraNode.simdOrientation = simd_quatf(
            ix: Float(qd2.imag.x), iy: Float(qd2.imag.y), iz: Float(qd2.imag.z), r: Float(qd2.real))
    }
}

// MARK: - assembly

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let scene = buildScene()
let cameraNode = SCNNode()
cameraNode.camera = SCNCamera()
cameraNode.camera!.zNear = 0.01
cameraNode.camera!.zFar = 80
scene.rootNode.addChildNode(cameraNode)

let view = MagicWindowView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
view.scene = scene
view.antialiasingMode = .multisampling4X
view.preferredFramesPerSecond = 120
view.rendersContinuously = true
view.client = PoseClient(path: "/tmp/wabe.sock")
view.cameraNode = cameraNode
view.delegate = view

let win = NSWindow(
    contentRect: view.frame,
    styleMask: [.titled, .closable, .resizable, .miniaturizable],
    backing: .buffered, defer: false)
win.title = "wabe — screen-rotation   (m mode · r recenter · [ ] eye dist · q quit)"
win.contentView = view
win.center()
win.makeKeyAndOrderFront(nil)
win.makeFirstResponder(view)
app.activate(ignoringOtherApps: true)
app.run()
