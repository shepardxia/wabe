// Eye, panel, world — with no view attached.
//
// The screen is a mirror. What you see is the piazza behind you, reflected in the glass, and the
// reason it is a mirror rather than a window is the reflection law: turn a mirror by one degree and
// the reflected ray turns by two. That doubles the demo's sensitivity to the one number wabe exists
// to publish, and it survives not knowing where your head is — a wrong eye costs a roughly static
// offset while the signal is the whole 2x sweep. A window has neither property.
//
// All the geometry lives here and nothing in this file knows what it is being drawn into. That
// matters for one practical reason: `SCNView` requires a window, and a window on macOS cannot be
// reliably kept out of the way — AppKit re-constrains it onto a display as it is ordered in, and
// activating the app drags the user's Space along with it. A still that has to appear on screen to
// be taken is a still nobody can take while working. `SCNRenderer` needs no window, so `--shot` and
// `--verify` drive this class directly and never create one.
//
// The other half of the reason is correctness: a still is then the same computation as a frame,
// not a second implementation of it that can drift.
import CoreGraphics
import SceneKit
import simd

/// The window's rectangle on the glass, in **meters**, relative to the hinge axis. The window is
/// the panel — wherever it sits on the display, whatever size it is.
///
/// Deliberately free of AppKit: working out which display the window is on, and how many meters a
/// point is worth there, is the shell's job (see `glassRect(viewSize:on:screenFrame:)`). Taking an
/// `NSScreen` here would mean this file — the one whose whole claim is that it knows nothing about
/// what it is drawn into — could not be exercised without a real attached display, and the panel's
/// physical size is precisely the number the demo's correctness rests on.
struct GlassRect {
    var offR = 0.0, offU = SCREEN_H / 2 + HINGE_GAP
    var w = SCREEN_W, h = SCREEN_H
}

final class Apparatus {
    /// What the camera should be for one frame, plus everything the overlay draws.
    struct Frame {
        var eye: SIMD3<Double>
        var orientation: simd_quatd
        var projection: simd_double4x4
        var construction: Construction
    }

    /// Distance from the panel's centre to the eye, meters. Brunelleschi held his panel at about
    /// this — close enough that the field is wide, close enough that the peephole forces the one
    /// viewpoint the picture was built for. It also sets the field of view outright, since the
    /// window is a fixed size: nearer is wider.
    var eyeDist = 0.20
    var showLines = true

    let worldNode: SCNNode

    private var refPanel: Panel?      // panel pose at recenter
    private var eyeDir = SIMD3<Double>(0, -1, 0)  // unit, horizontal, panel -> eye
    private var anchored = false
    /// Where the piazza sits in the room, fixed at recenter. The node's own transform is this with
    /// the mirror reflection applied on top, rebuilt every frame because the mirror moves.
    private var placement = matrix_identity_float4x4

    init(worldNode: SCNNode) { self.worldNode = worldNode }

    /// Forget the eye and the piazza's anchor; both are re-derived from the next pose that arrives.
    /// This is the apparatus being set down and picked up again.
    func reseat() {
        refPanel = nil
        anchored = false
    }

    func nudgeEye(_ delta: Double) { eyeDist = min(1.0, max(0.14, eyeDist + delta)) }

    /// The panel in world coordinates. World origin is the hinge axis, so the panel swings about
    /// the origin exactly as the physical lid swings about the hinge.
    private func panel(_ screenQ: simd_quatd, _ glass: GlassRect) -> Panel {
        let vr = screenQ.act(SIMD3<Double>(1, 0, 0))   // right, along the hinge
        let vu = screenQ.act(SIMD3<Double>(0, 0, 1))   // up the glass
        let vn = screenQ.act(SIMD3<Double>(0, -1, 0))  // outward, toward the viewer
        return Panel(center: vr * glass.offR + vu * glass.offU,
                     right: vr, up: vu, normal: vn, width: glass.w, height: glass.h)
    }

    /// One frame's worth of geometry. Unfiltered: the lid angle is the signal, and smoothing it is
    /// smoothing away the thing being shown.
    func update(baseQ liveQ: simd_quatd, lid liveLid: Double, hasPose: Bool, connected: Bool,
                glass: GlassRect) -> Frame {
        let baseQ = liveQ
        let lid = liveLid

        // Screen pose: chassis attitude composed with the hinge. The sign is easy to get backwards:
        // orientation.c defines the face normal as base +Z rotated about +X by (180 - lid), which
        // is this rotation applied to (0,-1,0). The mirrored (lid - 90) agrees only at lid 90 and
        // puts the screen 83 degrees out at 131.
        let hinge = simd_quatd(angle: (90 - lid) * .pi / 180, axis: SIMD3(1, 0, 0))
        let q = baseQ * hinge

        // Capture the reference before --yaw, never after. Folding the offset into the pose first
        // puts it in both q and the reference, where it cancels and the flag silently does nothing.
        // And anchor only once the pose is real: until then the client is still handing out its
        // placeholder attitude, and pinning the eye and the piazza to that leaves the whole scene
        // rotated by however far the laptop actually was from flat, permanently, until someone
        // presses r. Overrides count as real, since they are the pose by definition.
        if refPanel == nil && hasPose {
            refPanel = panel(q, glass)
        }

        var frame = mirror(panel(q, glass), lid: lid)
        frame.construction.showLines = showLines
        frame.construction.connected = connected
        return frame
    }

    /// Put the piazza in the room, once. Everything after this is the panel moving against a world
    /// that does not.
    private func anchor(to ref: Panel) {
        eyeDir = horizontalGaze(ref.normal)
        let station = ref.center + eyeDir * eyeDist - SIMD3(0, 0, EYE_HEIGHT)
        // Piazza +Y is the way you were looking; the pavement stays level because up is gravity.
        let forward = -eyeDir
        let psi = atan2(forward.y, forward.x) - .pi / 2
        placement = simd_float4x4(columns: (
            SIMD4(Float(cos(psi)), Float(sin(psi)), 0, 0),
            SIMD4(Float(-sin(psi)), Float(cos(psi)), 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(Float(station.x), Float(station.y), Float(station.z), 1)))
        anchored = true
    }

    /// The direction from the panel to the eye: the screen normal flattened onto the horizontal.
    /// With the lid near flat the normal has no heading left to project, so the last good one
    /// stands rather than snapping the viewer through 90 degrees on a rounding error.
    private func horizontalGaze(_ normal: SIMD3<Double>,
                                fallback: SIMD3<Double> = SIMD3(0, -1, 0)) -> SIMD3<Double> {
        let h = SIMD3(normal.x, normal.y, 0)
        return simd_length(h) < 0.02 ? fallback : simd_normalize(h)
    }

    /// Reflection about the panel's plane, as a transform on the world.
    ///
    /// `I - 2nn'` about the plane through the panel's centre. Its determinant is -1, which is why
    /// every material in the scene is double sided: the reflection reverses each triangle's winding
    /// and back-face culling would then discard exactly what should be visible.
    private func reflection(about p: Panel) -> simd_float4x4 {
        let n = p.normal
        let d = 2 * dot(p.center, n)
        var m = matrix_identity_float4x4
        for i in 0..<3 {
            for j in 0..<3 {
                m[i][j] = Float((i == j ? 1 : 0) - 2 * n[i] * n[j])
            }
            m[3][i] = Float(d * n[i])
        }
        return m
    }

    /// A piazza direction in room coordinates *without* the mirror — where the thing really is, as
    /// opposed to where it appears. Only the sun needs this, to light the glass it is reflecting in.
    private func unreflected(_ d: SIMD3<Double>) -> SIMD3<Double> {
        let o = placement * SIMD4<Float>(0, 0, 0, 1)
        let v = placement * SIMD4<Float>(Float(d.x), Float(d.y), Float(d.z), 1)
        return simd_normalize(SIMD3(Double(v.x - o.x), Double(v.y - o.y), Double(v.z - o.z)))
    }

    /// Piazza coordinates to world coordinates, matching `worldNode`'s transform exactly. The
    /// overlay traces the same lines the renderer drew, so it has to walk the same path.
    func toWorld(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let m = worldNode.simdTransform
        let v = m * SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), 1)
        return SIMD3(Double(v.x), Double(v.y), Double(v.z))
    }

    private func mirror(_ p: Panel, lid: Double) -> Frame {
        guard let ref = refPanel else {
            return Frame(eye: .zero, orientation: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
                         projection: simd_double4x4(1), construction: Construction(principal: .zero))
        }
        if !anchored { anchor(to: ref) }

        // Level with the panel's centre and squarely in front of it in plan, wherever the screen is
        // now pointing. Level, not out along the panel's own axis: the lid leans the screen back
        // and your head does not follow it down, and that gap is precisely what the peephole
        // measures. `[` and `]` walk the eye in and out along the same line.
        eyeDir = horizontalGaze(p.normal, fallback: eyeDir)
        let eye = p.center + eyeDir * eyeDist

        // Reflect the world, not the camera. Seen through the ordinary off-axis frustum, the
        // mirrored scene *is* the reflection: the ray from the eye to a point on the glass, carried
        // on into the mirrored world, traces exactly the path light takes bouncing off it. Building
        // a camera behind the mirror instead needs a left-handed basis, which the quaternion the
        // camera node wants cannot represent.
        worldNode.simdTransform = reflection(about: p) * placement

        let f = Frustum(panel: p, eye: eye, near: NEAR, far: FAR)
        var c = Construction(principal: f.principalPoint)
        // Everything the construction names is read through `toWorld`, which now carries the
        // reflection — so the horizon is the mirrored ground's horizon and the orthogonals are the
        // mirrored bands, which is what is actually on screen. Hardcoding world +Z as the ground
        // normal here would draw the horizon of a pavement nobody can see.
        let origin = toWorld(SIMD3(0, 0, 0))
        let forward = simd_normalize(toWorld(SIMD3(0, 1, 0)) - origin)
        let groundUp = simd_normalize(toWorld(SIMD3(0, 0, 1)) - origin)
        c.vanishing = f.ndc(direction: forward)
        c.horizon = f.vanishingLine(planeNormal: groundUp).clippedToUnitSquare()
        c.orthogonals = Piazza.orthogonals.compactMap { projectSegment(f, toWorld($0.0), toWorld($0.1)) }
        c.transversals = Piazza.transversals.compactMap { projectSegment(f, toWorld($0.0), toWorld($0.1)) }

        // The sun is geometry under the world node, so `toWorld` gives its *reflected* direction —
        // exactly where the renderer draws the disc, so the bloom lands on the sun rather than
        // merely agreeing with it. The strength is the ordinary specular term against the real sun,
        // and the two agree by construction: the half vector lines up with the normal precisely
        // when the reflected sun heads back at the eye.
        c.glint = f.ndc(direction: simd_normalize(toWorld(Piazza.sunDirection) - origin))
        let toEye = simd_normalize(eye - p.center)
        let sun = unreflected(Piazza.sunDirection)
        c.glintStrength = max(0, dot(p.normal, simd_normalize(sun + toEye)))

        c.lidDeg = lid
        c.elevationDeg = asin(max(-1, min(1, p.normal.z))) * 180 / .pi
        c.offAxisDeg = acos(max(-1, min(1, dot(p.normal, toEye)))) * 180 / .pi
        c.eyeDist = eyeDist
        return Frame(eye: eye, orientation: simd_quatd(f.basis), projection: f.projection,
                     construction: c)
    }
}

/// simd's column-major layout onto SCNMatrix4's row-vector naming: `P[i][j]` is column i, row j,
/// which is SCNMatrix4's `m(i+1)(j+1)`. Getting this transposed renders a black screen and looks
/// like a scene bug.
func scnMatrix(_ p: simd_double4x4) -> SCNMatrix4 {
    SCNMatrix4(
        m11: CGFloat(p[0][0]), m12: CGFloat(p[0][1]), m13: CGFloat(p[0][2]), m14: CGFloat(p[0][3]),
        m21: CGFloat(p[1][0]), m22: CGFloat(p[1][1]), m23: CGFloat(p[1][2]), m24: CGFloat(p[1][3]),
        m31: CGFloat(p[2][0]), m32: CGFloat(p[2][1]), m33: CGFloat(p[2][2]), m34: CGFloat(p[2][3]),
        m41: CGFloat(p[3][0]), m42: CGFloat(p[3][1]), m43: CGFloat(p[3][2]), m44: CGFloat(p[3][3]))
}

extension Apparatus.Frame {
    /// Point a camera node at what this frame says.
    func apply(to cameraNode: SCNNode) {
        cameraNode.simdPosition = SIMD3<Float>(eye)
        cameraNode.simdOrientation = simd_quatf(ix: Float(orientation.imag.x),
                                                iy: Float(orientation.imag.y),
                                                iz: Float(orientation.imag.z),
                                                r: Float(orientation.real))
        cameraNode.camera?.projectionTransform = scnMatrix(projection)
    }
}
