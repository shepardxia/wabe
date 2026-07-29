import simd

/// Chip→base axis maps, measured 2026-07-28 on Mac16,6 (gravity holds on three orientations +
/// two rotation-sign tests; see NOTES.md). The readout triad is LEFT-handed: chip +x = laptop
/// left, +y = front, +z = down. Base frame: X = right, Y = toward hinge, Z = up.
///
/// Accel (true vector) maps by full negation; gyro rates map by identity — a pseudo-vector picks
/// up the det(−I) = −1 under the improper transform, and both signs were confirmed empirically
/// (z: CCW spin, x: front-edge lift; y untested individually but pinned by the same global law).
@inlinable
public func accelChipToBase(_ v: SIMD3<Double>) -> SIMD3<Double> {
    -v
}

@inlinable
public func gyroChipToBase(_ v: SIMD3<Double>) -> SIMD3<Double> {
    v
}

/// Mahony-style complementary filter: gyro propagation, gravity correction on roll/pitch,
/// integral term absorbing gyro bias. Yaw is gyro-integrated only (unobservable without a
/// second reference) — consumers get it as *relative* heading via `recenter()`.
public final class MahonyFilter {
    public private(set) var q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)  // base -> world
    public private(set) var gyroBias = SIMD3<Double>()
    public private(set) var stationary = false

    private let kp: Double
    private let ki: Double
    private var lastT: Double?
    private var headingRef = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)

    // Stationary detector state: windowed extremes over the last second.
    private var windowStart = 0.0
    private var accMagMin = Double.infinity, accMagMax = -Double.infinity
    private var gyroMax = 0.0
    private var stillSince: Double?
    private var gyroWindowSum = SIMD3<Double>()
    private var gyroWindowN = 0

    public init(kp: Double = 2.0, ki: Double = 0.05) {
        self.kp = kp
        self.ki = ki
    }

    public func update(accel: SIMD3<Double>, gyroDegS: SIMD3<Double>, t: Double) {
        guard let t0 = lastT else {
            lastT = t
            // Initialize attitude from gravity alone (yaw arbitrary = 0).
            q = Self.attitudeFromGravity(accel)
            headingRef = q
            return
        }
        let dt = t - t0
        lastT = t
        guard dt > 0, dt < 0.5 else { return }

        updateStationary(accel: accel, gyroDegS: gyroDegS, t: t)

        let omega = (gyroDegS - gyroBias) * (.pi / 180)

        // Gravity correction: error = measured down (body) x predicted down (body).
        var e = SIMD3<Double>()
        let accMag = length(accel)
        if accMag > 0.5, accMag < 1.5 {  // distrust accel during real shoving
            let measuredDown = -accel / accMag  // accel at rest reads +1 g opposite gravity
            let predictedDown = q.inverse.act(SIMD3(0, 0, -1))
            e = cross(measuredDown, predictedDown)
        }

        gyroBias -= e * ki * dt * (180 / .pi)
        let corrected = omega + e * kp
        let dq = simd_quatd(real: 0, imag: corrected) * q
        q = simd_normalize(simd_quatd(
            ix: q.imag.x + 0.5 * dq.imag.x * dt,
            iy: q.imag.y + 0.5 * dq.imag.y * dt,
            iz: q.imag.z + 0.5 * dq.imag.z * dt,
            r: q.real + 0.5 * dq.real * dt))
    }

    /// Laptop-intuitive angles, radians. Roll/pitch absolute (gravity), yaw relative to the last
    /// recenter. Signs: pitch + = front edge up, roll + = right side down, yaw + = CCW from above.
    public var rollPitchYaw: SIMD3<Double> {
        let rel = headingRef.inverse * q
        let R = simd_matrix3x3(q)
        let aboutX = atan2(R[1][2], R[2][2])   // math-euler angle about base X (left-right axis)
        let aboutY = -asin(max(-1, min(1, R[0][2])))  // about base Y (front-back axis)
        let Rrel = simd_matrix3x3(rel)
        let yaw = atan2(Rrel[0][1], Rrel[0][0])
        return SIMD3(aboutY, -aboutX, yaw)  // (roll, pitch, yaw) in laptop terms
    }

    public func recenter() { headingRef = q }

    private static func attitudeFromGravity(_ accel: SIMD3<Double>) -> simd_quatd {
        let up = normalize(accel)  // at rest accel points opposite gravity = world up
        return simd_quatd(from: up, to: SIMD3(0, 0, 1))
    }

    private func updateStationary(accel: SIMD3<Double>, gyroDegS: SIMD3<Double>, t: Double) {
        let m = length(accel)
        accMagMin = min(accMagMin, m)
        accMagMax = max(accMagMax, m)
        gyroMax = max(gyroMax, length(gyroDegS - gyroBias))
        gyroWindowSum += gyroDegS  // raw, pre-bias: the window mean of a still window IS the bias
        gyroWindowN += 1
        guard t - windowStart >= 1.0 else { return }

        let still = (accMagMax - accMagMin) < 0.02 && gyroMax < 1.5
        if still {
            if stillSince == nil { stillSince = t }
            // Stationary bias refresh. This is the only correction path for z (yaw) bias —
            // gravity error has no z-component — and it sharpens x/y beyond what ki achieves.
            // Blend rather than snap so a borderline-still window can't kick the rates.
            if gyroWindowN > 0 {
                let mean = gyroWindowSum / Double(gyroWindowN)
                gyroBias += (mean - gyroBias) * 0.5
            }
        } else {
            stillSince = nil
        }
        stationary = still && (t - (stillSince ?? t)) >= 0.0

        windowStart = t
        accMagMin = .infinity
        accMagMax = -.infinity
        gyroMax = 0
        gyroWindowSum = SIMD3<Double>()
        gyroWindowN = 0
    }
}

/// Screen-plane pose: base attitude ⊕ lid angle. The hinge axis is +x of the base frame
/// (PROVISIONAL, same caveat as above). Lid angle 0 = closed, ~110 = typical open. The screen
/// normal at lid angle θ points away from the display face.
public enum ScreenPose {
    public static func screenNormal(baseQ: simd_quatd, lidDeg: Double) -> SIMD3<Double> {
        let theta = (180 - lidDeg) * .pi / 180  // closed lid: normal flat against keyboard
        let hinge = simd_quatd(angle: theta, axis: SIMD3(1, 0, 0))
        // Screen face normal when fully flat-open (180°) would be straight up in base frame.
        let normalInBase = hinge.act(SIMD3(0, 0, 1))
        return baseQ.act(normalInBase)
    }
}
