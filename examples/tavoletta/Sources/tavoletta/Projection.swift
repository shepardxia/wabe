// The perspective construction, in one place.
//
// Brunelleschi's demonstration is a claim about three things and the relations between them: an
// eye, a panel, and a world. Fix the eye and the world, move the panel, and the picture on the
// panel has to change in a way that is fully determined — that determination is what this file
// computes. Kooima's off-axis frustum gives the picture; the same matrix, read back, gives the
// vanishing point, the horizon, and the principal point, which are the construction lines drawn
// on top of it. They are measurements of the render, not decorations over it.
//
// World frame is wabe's: X right, Y forward, Z up (gravity). Meters.
import CoreGraphics
import simd

/// The physical display as a rectangle in space: where light passes through. Placed by wabe's
/// chassis attitude composed with the lid angle.
struct Panel {
    var center: SIMD3<Double>
    var right: SIMD3<Double>   // unit, panel +u (screen right)
    var up: SIMD3<Double>      // unit, panel +v (screen up)
    var normal: SIMD3<Double>  // unit, outward, toward the viewer
    var width: Double          // meters
    var height: Double

    var lowerLeft: SIMD3<Double> { center - right * (width / 2) - up * (height / 2) }
    var lowerRight: SIMD3<Double> { center + right * (width / 2) - up * (height / 2) }
    var upperLeft: SIMD3<Double> { center - right * (width / 2) + up * (height / 2) }
}

/// A line in normalized device coordinates, `a·x + b·y + c = 0`.
struct NDCLine {
    var a: Double, b: Double, c: Double

    /// The segment of this line inside the visible square, or nil if it misses it. Endpoints come
    /// back in NDC, so the caller scales them to whatever the view happens to be.
    func clippedToUnitSquare() -> (SIMD2<Double>, SIMD2<Double>)? {
        var hits: [SIMD2<Double>] = []
        let eps = 1e-9
        if abs(b) > eps {
            for x in [-1.0, 1.0] {
                let y = -(a * x + c) / b
                if y >= -1.0001 && y <= 1.0001 { hits.append(SIMD2(x, y)) }
            }
        }
        if abs(a) > eps {
            for y in [-1.0, 1.0] {
                let x = -(b * y + c) / a
                if x >= -1.0001 && x <= 1.0001 { hits.append(SIMD2(x, y)) }
            }
        }
        guard hits.count >= 2 else { return nil }
        // Two of the four candidates can coincide exactly at a corner; take the widest pair.
        var best = (hits[0], hits[1])
        var bestD = -1.0
        for i in 0..<hits.count {
            for j in (i + 1)..<hits.count {
                let d = simd_distance(hits[i], hits[j])
                if d > bestD { bestD = d; best = (hits[i], hits[j]) }
            }
        }
        return bestD > 1e-6 ? best : nil
    }
}

/// An off-axis frustum: eye somewhere in the room, panel somewhere else, picture determined.
/// Kooima, "Generalized Perspective Projection" (2008).
struct Frustum {
    let eye: SIMD3<Double>
    /// Camera basis: columns are the panel's right, up, and outward normal. The camera sits at
    /// the eye and looks along -normal, which is into the scene.
    let basis: simd_double3x3
    let projection: simd_double4x4

    private var p00: Double { projection[0][0] }
    private var p11: Double { projection[1][1] }
    private var p20: Double { projection[2][0] }
    private var p21: Double { projection[2][1] }

    init(panel: Panel, eye: SIMD3<Double>, near: Double, far: Double) {
        self.eye = eye
        let vr = panel.right, vu = panel.up, vn = panel.normal
        basis = simd_double3x3(columns: (vr, vu, vn))

        let va = panel.lowerLeft - eye
        let vb = panel.lowerRight - eye
        let vc = panel.upperLeft - eye
        // Distance from the eye to the panel plane. Clamped: edge-on, the frustum degenerates and
        // the picture is undefined rather than merely extreme.
        let d = max(0.02, -dot(va, vn))
        let l = dot(vr, va) * near / d
        let r = dot(vr, vb) * near / d
        let b = dot(vu, va) * near / d
        let t = dot(vu, vc) * near / d

        var p = simd_double4x4(0)
        p[0][0] = 2 * near / (r - l)
        p[1][1] = 2 * near / (t - b)
        p[2][0] = (r + l) / (r - l)
        p[2][1] = (t + b) / (t - b)
        p[2][2] = -(far + near) / (far - near)
        p[2][3] = -1
        p[3][2] = -2 * far * near / (far - near)
        projection = p
    }

    /// Where a camera-space ray direction lands on the panel. Nil when it points behind the eye,
    /// which is the honest answer: that direction has no image.
    private func project(cameraRay v: SIMD3<Double>) -> SIMD2<Double>? {
        guard v.z < -1e-9 else { return nil }
        let w = -v.z
        return SIMD2((p00 * v.x + p20 * v.z) / w, (p11 * v.y + p21 * v.z) / w)
    }

    func toCamera(_ world: SIMD3<Double>) -> SIMD3<Double> { basis.transpose * world }

    /// Image of a world point.
    func ndc(point p: SIMD3<Double>) -> SIMD2<Double>? { project(cameraRay: toCamera(p - eye)) }

    /// Image of a world direction: the vanishing point of every line parallel to it.
    func ndc(direction d: SIMD3<Double>) -> SIMD2<Double>? { project(cameraRay: toCamera(d)) }

    /// The vanishing line of every plane with this normal — the horizon, for normal = up.
    ///
    /// Derived rather than sampled: inverting the projection, the NDC point (x, y) corresponds to
    /// the camera ray ((x + p20)/p00, (y + p21)/p11, -1), and that ray is parallel to the plane
    /// exactly when it is perpendicular to the plane's normal. Sampling two directions instead
    /// fails whenever one of them happens to fall behind the eye, which for a horizon is often.
    func vanishingLine(planeNormal m: SIMD3<Double>) -> NDCLine {
        let mc = toCamera(m)
        return NDCLine(a: mc.x / p00,
                       b: mc.y / p11,
                       c: mc.x * p20 / p00 + mc.y * p21 / p11 - mc.z)
    }

    /// The principal point: where the panel's own perpendicular through the eye pierces it. This
    /// is Brunelleschi's peephole. It sits at the centre of the panel exactly when the panel faces
    /// the eye square on, so its drift off centre *is* the screen normal, drawn.
    var principalPoint: SIMD2<Double> { SIMD2(-p20, -p21) }
}

/// NDC to view coordinates, AppKit's bottom-left origin, in points.
func viewPoint(_ ndc: SIMD2<Double>, size: CGSize) -> CGPoint {
    CGPoint(x: (ndc.x + 1) / 2 * size.width, y: (ndc.y + 1) / 2 * size.height)
}

/// Everything the overlay draws, measured off the frustum that drew the frame beneath it.
struct Construction {
    /// Vanishing point of the pavement's orthogonals, if it has an image at all.
    var vanishing: SIMD2<Double>? = nil
    /// Horizon: the vanishing line of the ground plane, clipped to the panel.
    var horizon: (SIMD2<Double>, SIMD2<Double>)? = nil
    /// Brunelleschi's peephole.
    var principal: SIMD2<Double>
    /// Images of the pavement's orthogonals, one segment each, already clipped to the panel.
    var orthogonals: [(SIMD2<Double>, SIMD2<Double>)] = []
    /// Images of the pavement's transversals — the lines parallel to the panel's bottom edge.
    var transversals: [(SIMD2<Double>, SIMD2<Double>)] = []

    /// Where the sun's reflection sits on the panel, treating the glass as the mirror it is.
    /// Nil when the sun is behind the screen and there is nothing to catch.
    ///
    /// This is the most sensitive readout of the screen normal there is, and the reason is the
    /// reflection law: turn a mirror by one degree and the reflected ray turns by two. The glint
    /// crosses the panel at twice the rate the lid moves.
    var glint: SIMD2<Double>? = nil
    /// How squarely the panel is catching the sun, 0 to 1: the specular alignment at its centre.
    var glintStrength: Double = 0

    var lidDeg: Double = 0
    /// Angle of the screen normal above the horizontal.
    var elevationDeg: Double = 0
    /// Angle between the screen normal and the direction from the panel's centre to the eye. Zero
    /// when the screen faces you square on, which is when the peephole is centred.
    var offAxisDeg: Double = 0
    var eyeDist: Double = 0
    var showLines = true
    var connected = true
}

/// Clip a segment to the visible square (Liang-Barsky). Returns nil if it misses entirely.
func clipToUnitSquare(_ p0: SIMD2<Double>, _ p1: SIMD2<Double>) -> (SIMD2<Double>, SIMD2<Double>)? {
    var t0 = 0.0, t1 = 1.0
    let d = p1 - p0
    for (p, q) in [(-d.x, p0.x + 1), (d.x, 1 - p0.x), (-d.y, p0.y + 1), (d.y, 1 - p0.y)] {
        if abs(p) < 1e-12 {
            if q < 0 { return nil }
        } else {
            let t = q / p
            if p < 0 { if t > t1 { return nil }; t0 = max(t0, t) } else { if t < t0 { return nil }; t1 = min(t1, t) }
        }
    }
    return (p0 + d * t0, p0 + d * t1)
}

/// Image of a world segment, clipped in 3D against the eye plane before projection so that a line
/// running from in front of the eye to behind it still draws the part that has an image.
func projectSegment(_ f: Frustum, _ a: SIMD3<Double>, _ b: SIMD3<Double>) -> (SIMD2<Double>, SIMD2<Double>)? {
    var ca = f.toCamera(a - f.eye)
    var cb = f.toCamera(b - f.eye)
    let zNear = -1e-3
    if ca.z > zNear && cb.z > zNear { return nil }
    if ca.z > zNear { ca = cb + (ca - cb) * ((zNear - cb.z) / (ca.z - cb.z)) }
    if cb.z > zNear { cb = ca + (cb - ca) * ((zNear - ca.z) / (cb.z - ca.z)) }
    let pa = SIMD2((f.projection[0][0] * ca.x + f.projection[2][0] * ca.z) / -ca.z,
                   (f.projection[1][1] * ca.y + f.projection[2][1] * ca.z) / -ca.z)
    let pb = SIMD2((f.projection[0][0] * cb.x + f.projection[2][0] * cb.z) / -cb.z,
                   (f.projection[1][1] * cb.y + f.projection[2][1] * cb.z) / -cb.z)
    return clipToUnitSquare(pa, pb)
}
