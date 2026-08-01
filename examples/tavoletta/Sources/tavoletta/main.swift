// tavoletta — Brunelleschi's mirror, held by your MacBook's screen.
//
// In 1425 Brunelleschi painted the Florence Baptistery on a small panel, drilled a hole through it
import AppKit
import SceneKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let (scene, worldNode) = Piazza.build()
let cameraNode = SCNNode()
cameraNode.camera = SCNCamera()
cameraNode.camera!.zNear = NEAR
cameraNode.camera!.zFar = FAR
scene.rootNode.addChildNode(cameraNode)

let view = TavolettaView(frame: NSRect(x: 0, y: 0, width: 1280, height: 840))
view.scene = scene
view.antialiasingMode = .multisampling4X
// The mirror turns every millisecond of latency into twice the angular error, and the scene costs
// about 3 ms a frame, so there is no reason to render at half the display's rate.
view.preferredFramesPerSecond = 120
view.rendersContinuously = true
view.autoresizingMask = [.width, .height]
view.client = PoseClient(path: "/tmp/wabe.sock")
view.rig = Apparatus(worldNode: worldNode)
view.cameraNode = cameraNode
view.delegate = view

let overlay = OverlayView(frame: view.bounds)
overlay.autoresizingMask = [.width, .height]
overlay.wantsLayer = true
view.addSubview(overlay)
view.overlay = overlay

let win = NSWindow(contentRect: view.frame,
                   styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)
win.title = "wabe — mirror   (l lines · r recenter · [ ] eye · q quit)"
win.contentView = view
win.center()
win.makeKeyAndOrderFront(nil)
win.makeFirstResponder(view)
app.activate(ignoringOtherApps: true)
app.run()
