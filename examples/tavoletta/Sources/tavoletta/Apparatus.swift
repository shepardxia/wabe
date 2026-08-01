import CoreGraphics
import SceneKit
import simd

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

        let hinge = simd_quatd(angle: (90 - lid) * .pi / 180, axis: SIMD3(1, 0, 0))
        let q = baseQ * hinge

        if refPanel == nil && hasPose {
            refPanel = panel(q, glass)
        }

        var frame = mirror(panel(q, glass), lid: lid)
        frame.construction.showLines = showLines
        frame.construction.connected = connected
        return frame
    }

    private func anchor(to ref: Panel) {
        eyeDir = horizontalGaze(ref.normal)
        let station = ref.center + eyeDir * eyeDist - SIMD3(0, 0, EYE_HEIGHT)
        let forward = eyeDir
        let psi = atan2(forward.y, forward.x) - .pi / 2
        placement = simd_float4x4(columns: (
            SIMD4(Float(cos(psi)), Float(sin(psi)), 0, 0),
            SIMD4(Float(-sin(psi)), Float(cos(psi)), 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(Float(station.x), Float(station.y), Float(station.z), 1)))
        anchored = true
    }

    private func horizontalGaze(_ normal: SIMD3<Double>,
                                fallback: SIMD3<Double> = SIMD3(0, -1, 0)) -> SIMD3<Double> {
        let h = SIMD3(normal.x, normal.y, 0)
        return simd_length(h) < 0.02 ? fallback : simd_normalize(h)
    }

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

        eyeDir = horizontalGaze(p.normal, fallback: eyeDir)
        let eye = p.center + eyeDir * eyeDist

        worldNode.simdTransform = reflection(about: p) * placement

        let f = Frustum(panel: p, eye: eye, near: NEAR, far: FAR)
        var c = Construction(principal: f.principalPoint)
        let origin = toWorld(SIMD3(0, 0, 0))
        let forward = simd_normalize(toWorld(SIMD3(0, 1, 0)) - origin)
        let groundUp = simd_normalize(toWorld(SIMD3(0, 0, 1)) - origin)
        c.vanishing = f.ndc(direction: forward)
        c.horizon = f.vanishingLine(planeNormal: groundUp).clippedToUnitSquare()
        c.orthogonals = Piazza.orthogonals.compactMap { projectSegment(f, toWorld($0.0), toWorld($0.1)) }
        c.transversals = Piazza.transversals.compactMap { projectSegment(f, toWorld($0.0), toWorld($0.1)) }

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
