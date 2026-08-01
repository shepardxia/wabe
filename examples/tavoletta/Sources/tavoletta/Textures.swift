// The paint. Everything the demo shows is drawn here with Core Graphics — no image files, no
// downloads, nothing to fetch.
//
import AppKit
import simd

enum Tex {
    /// The panel palette. Textures and geometry both draw from here so the two agree.
    enum Palette {
        static func hex(_ v: UInt32, _ alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                    green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255,
                    alpha: alpha)
        }

        static let skyZenith = hex(0x8FB4D6)
        static let skyHorizon = hex(0xE8DCC0)
        static let ground = hex(0xB9A98C)      // pavement field
        static let band = hex(0xEDE6D4)        // pavement marble bands
        static let carrara = hex(0xF2EDE0)     // white marble
        static let prato = hex(0x4E6B57)       // green serpentine inlay
        static let rose = hex(0xC08A7A)        // Maremma rose, the Duomo's third stone
        static let stucco = hex(0xD8BE96)
        static let roofTile = hex(0xA85E3C)
        static let granite = hex(0x8B8378)
        static let bronze = hex(0x7A6A3E)

        // Secondary tones, all derived from the same warm daylight key.
        static let gilt = hex(0xC7A24F)
        static let shutter = hex(0x7A6444)
        static let recess = hex(0x342B22)      // window and portal interiors
        static let iron = hex(0x3B372F)        // wrought iron: granite taken down to near-black
        static let wellShaft = hex(0x241F19)   // down the well, darker than any recess above ground
        static let black = hex(0x000000)
        static let white = hex(0xFFFFFF)
    }

    /// lit from another is the kind of wrongness nobody can name but everybody sees.
    static func skyCube(face: Int = 256, sun: SIMD3<Double>) -> [NSImage] {
        let n = max(8, face)
        return (0..<6).map { f in
            var px = [UInt8](repeating: 255, count: n * n * 4)
            for row in 0..<n {
                let v = 2 * (Double(row) + 0.5) / Double(n) - 1   // row 0 is the top of the image
                for col in 0..<n {
                    let u = 2 * (Double(col) + 0.5) / Double(n) - 1
                    // The standard cube-face frames, u right and v down across the image, giving
                    // the direction in the sampler's own space.
                    let s: SIMD3<Double>
                    switch f {
                    case 0: s = SIMD3(1, -v, -u)
                    case 1: s = SIMD3(-1, -v, u)
                    case 2: s = SIMD3(u, 1, v)
                    case 3: s = SIMD3(u, -1, -v)
                    case 4: s = SIMD3(u, -v, 1)
                    default: s = SIMD3(-u, -v, -1)
                    }
                    let d = simd_normalize(SIMD3(s.x, s.y, -s.z))
                    var c = skyColor(at: CGFloat((1 - d.z) / 2))

                    let cosA = simd_dot(d, sun)
                    let halo = pow(max(0, cosA), 260) * 0.85 + pow(max(0, cosA), 14) * 0.10
                    let disc = cosA > cos(1.6 * .pi / 180) ? 1.0 : 0.0
                    let glare = min(1.0, halo + disc)
                    if glare > 0.002 {
                        c = (blend(c.0, 255, glare), blend(c.1, 252, glare), blend(c.2, 232, glare))
                    }
                    let i = (row * n + col) * 4
                    px[i] = c.0; px[i + 1] = c.1; px[i + 2] = c.2
                }
            }
            return bitmap(px, n) ?? canvas(CGSize(width: n, height: n)) {
                $0.box(CGRect(x: 0, y: 0, width: n, height: n), Palette.skyHorizon)
            }
        }
    }

    static func revetment(tier: Int, size: CGSize) -> NSImage {
        canvas(size) { ctx in
            let w = size.width, h = size.height
            ctx.box(CGRect(origin: .zero, size: size), Palette.carrara)
            veining(ctx, size, seed: 0x5EED &+ UInt64(tier))

            let green = Palette.prato
            let lw = max(2, w * 0.011)

            switch tier {
            case 0:
                // Plinth, two corner pilasters, one large framed panel, entablature.
                ctx.box(CGRect(x: 0, y: 0, width: w, height: h * 0.085), green)
                ctx.box(CGRect(x: 0, y: h * 0.085, width: w, height: lw * 0.7),
                        mix(green, Palette.carrara, 0.45))

                for side in [0.045, 0.855] {
                    let r = CGRect(x: w * side, y: h * 0.10, width: w * 0.10, height: h * 0.78)
                    ctx.frame(r, green, lw)
                    ctx.box(CGRect(x: r.minX - w * 0.012, y: r.maxY, width: r.width + w * 0.024,
                                   height: h * 0.045), green)
                    ctx.box(CGRect(x: r.minX - w * 0.008, y: r.minY - h * 0.028,
                                   width: r.width + w * 0.016, height: h * 0.028), green)
                }

                let outer = CGRect(x: w * 0.215, y: h * 0.155, width: w * 0.57, height: h * 0.66)
                ctx.frame(outer, green, lw * 1.7)
                let inner = outer.insetBy(dx: w * 0.048, dy: h * 0.055)
                ctx.box(inner, mix(Palette.carrara, green, 0.10))
                ctx.frame(inner, green, lw)
                // A circle inside the panel — the register's only curved figure, and enough to
                // keep the near face from reading as blank at 65 m.
                ctx.circle(centre: CGPoint(x: inner.midX, y: inner.midY),
                           radius: min(inner.width, inner.height) * 0.30, green, lw)

                ctx.box(CGRect(x: 0, y: h * 0.90, width: w, height: h * 0.045), green)
                ctx.box(CGRect(x: 0, y: h * 0.955, width: w, height: h * 0.045), green)

            case 1:
                // Blind arcade: three round-headed bays.
                ctx.box(CGRect(x: 0, y: 0, width: w, height: h * 0.075), green)
                let bays = 3
                let margin = w * 0.055
                let pitch = (w - 2 * margin) / CGFloat(bays)
                for b in 0..<bays {
                    let cx = margin + pitch * (CGFloat(b) + 0.5)
                    let rad = pitch * 0.33
                    ctx.opening(archPath(cx: cx, base: h * 0.10, top: h * 0.50 + rad, half: rad),
                                fill: mix(Palette.carrara, green, 0.08),
                                jambs: [(green, lw * 1.8)])
                    // A small dark window in the centre bay only: the arcade is blind elsewhere.
                    if b == bays / 2 {
                        ctx.box(CGRect(x: cx - pitch * 0.09, y: h * 0.20,
                                       width: pitch * 0.18, height: h * 0.36), Palette.recess)
                    }
                }
                ctx.box(CGRect(x: 0, y: h * 0.895, width: w, height: h * 0.05), green)
                ctx.box(CGRect(x: 0, y: h * 0.965, width: w, height: h * 0.035), green)

            default:
                // Attic: a row of rectangular panels under the cornice.
                ctx.box(CGRect(x: 0, y: 0, width: w, height: h * 0.10), green)
                ctx.box(CGRect(x: 0, y: h * 0.80, width: w, height: h * 0.075), green)
                ctx.box(CGRect(x: 0, y: h * 0.90, width: w, height: h * 0.10), green)
                let panels = 5
                let margin = w * 0.05
                let pitch = (w - 2 * margin) / CGFloat(panels)
                for p in 0..<panels {
                    let r = CGRect(x: margin + pitch * CGFloat(p) + pitch * 0.12, y: h * 0.20,
                                   width: pitch * 0.76, height: h * 0.52)
                    ctx.frame(r, green, lw * 1.4)
                    ctx.box(r.insetBy(dx: lw * 2.2, dy: lw * 2.2), mix(Palette.carrara, green, 0.13))
                }
            }
        }
    }

    static func campanile(register: Int, size: CGSize) -> NSImage {
        canvas(size) { ctx in
            let w = size.width, h = size.height
            ctx.box(CGRect(origin: .zero, size: size), Palette.carrara)
            veining(ctx, size, seed: 0xCA97 &+ UInt64(register))

            let green = Palette.prato
            let lw = max(2, w * 0.012)

            // Each register is closed top and bottom by a green course. The geometry's cornice
            // lands directly above the upper one, so texture and box read as a single heavy string.
            ctx.box(CGRect(x: 0, y: 0, width: w, height: h * 0.055), green)
            ctx.box(CGRect(x: 0, y: h * 0.945, width: w, height: h * 0.055), green)

            // Corner pilasters, the same in every register so they run the whole 85 m unbroken.
            // The campanile's job in this scene is to give the eye a vertical to travel.
            for x in [0.0, 0.925] {
                let r = CGRect(x: w * x, y: h * 0.055, width: w * 0.075, height: h * 0.89)
                ctx.box(r, mix(Palette.carrara, green, 0.14))
                ctx.frame(r, green, lw)
            }

            let field = CGRect(x: w * 0.10, y: h * 0.075, width: w * 0.80, height: h * 0.85)

            switch register {
            case 0:
                // Two tall framed panels, each with an inscribed lozenge. Solid and heavy, and read
                // from close: this register starts 31 m from the eye and fills the frame's edge.
                for i in 0..<2 {
                    let r = CGRect(x: field.minX + field.width * (0.04 + 0.48 * CGFloat(i)),
                                   y: field.minY + field.height * 0.06,
                                   width: field.width * 0.44, height: field.height * 0.88)
                    ctx.frame(r, green, lw * 1.8)
                    let inner = r.insetBy(dx: w * 0.035, dy: h * 0.030)
                    ctx.box(inner, mix(Palette.carrara, Palette.rose, 0.16))
                    ctx.frame(inner, green, lw)
                    ctx.lozenge(inner.insetBy(dx: w * 0.030, dy: h * 0.055), green, lw * 1.2)
                }

            case 1:
                // A grid of small inlaid squares, rose and green alternating.
                let cols = 3, rows = 4
                let cw = field.width / CGFloat(cols), ch = field.height / CGFloat(rows)
                for r in 0..<rows {
                    for c in 0..<cols {
                        let cell = CGRect(x: field.minX + cw * CGFloat(c),
                                          y: field.minY + ch * CGFloat(r),
                                          width: cw, height: ch)
                            .insetBy(dx: cw * 0.14, dy: ch * 0.16)
                        ctx.frame(cell, green, lw * 1.4)
                        ctx.box(cell.insetBy(dx: lw * 2.0, dy: lw * 2.0),
                                (r + c) % 2 == 0 ? mix(Palette.carrara, Palette.rose, 0.35)
                                                 : mix(Palette.carrara, green, 0.18))
                    }
                }

            case 2:
                // Bifora: two round-headed lights under one blind hood, with a dark glazed recess.
                ctx.opening(archPath(cx: field.midX, base: field.minY, top: field.maxY,
                                     half: field.width * 0.46),
                            fill: mix(Palette.carrara, green, 0.06),
                            jambs: [(green, lw * 3.2), (mix(green, Palette.carrara, 0.4), lw)])
                for i in 0..<2 {
                    let cx = field.midX + field.width * (CGFloat(i) - 0.5) * 0.44
                    ctx.opening(archPath(cx: cx, base: field.minY + field.height * 0.10,
                                         top: field.maxY - field.height * 0.28,
                                         half: field.width * 0.15),
                                fill: Palette.recess,
                                jambs: [(Palette.carrara, lw * 2.4), (green, lw)])
                }
                ctx.box(CGRect(x: field.midX - lw, y: field.minY,
                               width: lw * 2, height: field.height * 0.62),
                        mix(Palette.carrara, green, 0.25))

            default:
                for i in 0..<3 {
                    let cx = field.minX + field.width * (CGFloat(i) + 0.5) / 3
                    ctx.opening(archPath(cx: cx, base: field.minY + field.height * 0.04,
                                         top: field.maxY - field.height * 0.06,
                                         half: field.width * 0.13),
                                fill: Palette.recess,
                                jambs: [(Palette.carrara, lw * 3.0), (green, lw * 1.2)])
                }
            }
        }
    }

    /// Palazzo facade: stucco with a grid of shuttered windows and a string course.
    static func palazzo(floors: Int, bays: Int, size: CGSize) -> NSImage {
        let floors = max(1, floors), bays = max(1, bays)
        return canvas(size) { ctx in
            let w = size.width, h = size.height
            ctx.box(CGRect(origin: .zero, size: size), Palette.stucco)
            grain(ctx, size, seed: UInt64(floors &* 131 &+ bays))

            let baseH = h * 0.16          // rusticated ground storey
            let friezeH = h * 0.08        // frieze below the (real, geometric) cornice
            let pitch = (h - baseH - friezeH) / CGFloat(floors)
            let bay = w / CGFloat(bays)
            let stone = mix(Palette.stucco, Palette.black, 0.13)
            let joint = mix(Palette.stucco, Palette.black, 0.34)
            let trim = mix(Palette.carrara, Palette.stucco, 0.35)

            ctx.box(CGRect(x: 0, y: 0, width: w, height: baseH), stone)
            for i in 1..<4 {
                let y = baseH * CGFloat(i) / 4
                ctx.box(CGRect(x: 0, y: y, width: w, height: max(2, h * 0.004)), joint)
            }
            // Ground-storey openings: round-headed, one per bay, deeply shadowed.
            for b in 0..<bays {
                let cx = bay * (CGFloat(b) + 0.5)
                let rad = bay * 0.20
                ctx.opening(archPath(cx: cx, base: baseH * 0.18, top: baseH * 0.55 + rad, half: rad),
                            fill: Palette.recess, jambs: [(trim, max(2, w * 0.004))])
            }

            // String courses: the horizontal family that has to converge with everything else.
            for f in 0...floors {
                let y = baseH + pitch * CGFloat(f)
                ctx.box(CGRect(x: 0, y: y - h * 0.006, width: w, height: h * 0.012), trim)
                ctx.box(CGRect(x: 0, y: y - h * 0.010, width: w, height: h * 0.004),
                        mix(Palette.stucco, Palette.black, 0.22))
            }

            for f in 0..<floors {
                for b in 0..<bays {
                    let ww = bay * 0.40, wh = pitch * 0.44
                    let cx = bay * (CGFloat(b) + 0.5)
                    let cy = baseH + pitch * (CGFloat(f) + 0.56)
                    let r = CGRect(x: cx - ww / 2, y: cy - wh / 2, width: ww, height: wh)
                    ctx.box(r.insetBy(dx: -ww * 0.11, dy: -wh * 0.07), trim)
                    ctx.box(r, Palette.recess)
                    let leaf = ww * 0.45
                    ctx.box(CGRect(x: r.minX + ww * 0.02, y: r.minY + wh * 0.04,
                                   width: leaf, height: wh * 0.92), Palette.shutter)
                    ctx.box(CGRect(x: r.maxX - ww * 0.02 - leaf, y: r.minY + wh * 0.04,
                                   width: leaf, height: wh * 0.92),
                            mix(Palette.shutter, Palette.black, 0.18))
                    ctx.box(CGRect(x: cx - ww * 0.72, y: r.minY - wh * 0.13,
                                   width: ww * 1.44, height: max(2, wh * 0.07)), Palette.carrara)
                }
            }

            ctx.box(CGRect(x: 0, y: h - friezeH, width: w, height: friezeH),
                    mix(Palette.stucco, Palette.carrara, 0.30))
            ctx.box(CGRect(x: 0, y: h - friezeH, width: w, height: max(2, h * 0.006)),
                    mix(Palette.stucco, Palette.black, 0.25))
        }
    }

    static func pavement(size: CGSize) -> NSImage {
        canvas(size) { ctx in
            ctx.box(CGRect(origin: .zero, size: size), Palette.ground)
            var rng = Seeded(0xB19A)
            let cs = srgb
            for _ in 0..<110 {
                let p = CGPoint(x: .random(in: 0...size.width, using: &rng),
                                y: .random(in: 0...size.height, using: &rng))
                let r = size.width * .random(in: 0.03...0.13, using: &rng)
                let lighter = Bool.random(using: &rng)
                let c = mix(Palette.ground, lighter ? Palette.white : Palette.black,
                            .random(in: 0.05...0.13, using: &rng))
                let a: CGFloat = .random(in: 0.20...0.45, using: &rng)
                guard let g = CGGradient(colorsSpace: cs,
                                         colors: [c.withAlphaComponent(a).cgColor,
                                                  c.withAlphaComponent(0).cgColor] as CFArray,
                                         locations: [0, 1]) else { continue }
                for dx in [-size.width, 0, size.width] {
                    for dy in [-size.height, 0, size.height] {
                        let q = CGPoint(x: p.x + dx, y: p.y + dy)
                        ctx.drawRadialGradient(g, startCenter: q, startRadius: 0,
                                               endCenter: q, endRadius: r, options: [])
                    }
                }
            }
            // Fine grit on top of the blotches, so the surface has something at pixel scale too.
            for _ in 0..<900 {
                let p = CGPoint(x: .random(in: 0...size.width, using: &rng),
                                y: .random(in: 0...size.height, using: &rng))
                let d = size.width * .random(in: 0.004...0.010, using: &rng)
                let c = mix(Palette.ground, Bool.random(using: &rng) ? Palette.white : Palette.black,
                            .random(in: 0.06...0.16, using: &rng))
                ctx.box(CGRect(x: p.x, y: p.y, width: d, height: d), c.withAlphaComponent(0.5))
            }
        }
    }

    static func duomoFacade(size: CGSize) -> NSImage {
        canvas(size) { ctx in
            let w = size.width, h = size.height
            ctx.box(CGRect(origin: .zero, size: size), Palette.carrara)
            courses(ctx, size, count: 30)   // 48 m over 30 bands ≈ the real 1.6 m course
            veining(ctx, size, seed: 0xD0D0)

            let green = Palette.prato
            let lw = max(2, w * 0.005)

            // Four vertical strips divide the front into three bays, one portal to each.
            for x in [0.04, 0.36, 0.64, 0.96] {
                ctx.box(CGRect(x: w * x - w * 0.012, y: 0, width: w * 0.024, height: h * 0.88),
                        mix(Palette.carrara, green, 0.22))
            }

            for p: (cx: CGFloat, half: CGFloat, top: CGFloat) in [(0.22, 0.046, 0.27),
                                                                  (0.50, 0.058, 0.35),
                                                                  (0.78, 0.046, 0.27)] {
                let cx = w * p.cx, half = w * p.half, base = h * 0.035, top = h * p.top
                ctx.opening(archPath(cx: cx, base: base, top: top, half: half),
                            fill: Palette.recess,
                            jambs: [(mix(Palette.carrara, Palette.rose, 0.30), w * 0.030),
                                    (green, w * 0.011)])
                doorway(ctx, cx: cx, base: base, top: top, half: half * 0.90)
            }

            // Rose window over the middle portal.
            let rc = CGPoint(x: w * 0.50, y: h * 0.585)
            let rr = w * 0.072
            ctx.box(CGRect(x: rc.x - rr * 1.35, y: rc.y - rr * 1.35,
                           width: rr * 2.7, height: rr * 2.7),
                    mix(Palette.carrara, green, 0.30))
            ctx.circle(centre: rc, radius: rr * 1.12, green, lw * 3)
            ctx.disc(centre: rc, radius: rr, Palette.recess)
            ctx.spokes(centre: rc, radius: rr, count: 12,
                       mix(Palette.carrara, Palette.rose, 0.2), lw * 1.6)
            ctx.circle(centre: rc, radius: rr * 0.42,
                       mix(Palette.carrara, Palette.rose, 0.2), lw * 2)

            // Blind niches in the flanking bays, level with the rose window.
            for x in [0.13, 0.31, 0.69, 0.87] {
                ctx.opening(archPath(cx: w * x, base: h * 0.46, top: h * 0.64, half: w * 0.028),
                            fill: mix(Palette.recess, Palette.carrara, 0.40),
                            jambs: [(mix(green, Palette.carrara, 0.25), w * 0.010)])
            }

            // Cornice and gable band closing the wall, and the flight at its foot echoing the real
            // steps the geometry puts in front of it.
            ctx.box(CGRect(x: 0, y: h * 0.875, width: w, height: h * 0.028), green)
            ctx.box(CGRect(x: 0, y: h * 0.915, width: w, height: h * 0.040),
                    mix(Palette.carrara, Palette.stucco, 0.22))
            ctx.box(CGRect(x: 0, y: h * 0.975, width: w, height: h * 0.025), Palette.rose)
            ctx.box(CGRect(x: w * 0.06, y: 0, width: w * 0.88, height: h * 0.018),
                    mix(Palette.carrara, Palette.ground, 0.30))
        }
    }

    static func duomoFlank(size: CGSize) -> NSImage {
        canvas(size) { ctx in
            let w = size.width, h = size.height
            ctx.box(CGRect(origin: .zero, size: size), Palette.carrara)
            courses(ctx, size, count: 25)
            veining(ctx, size, seed: 0xF1A4)

            let green = Palette.prato
            let bays = 6
            let pitch = w / CGFloat(bays)

            // Dado: the wall's own plinth, dark enough to sit 58 m of marble on the pavement.
            ctx.box(CGRect(x: 0, y: 0, width: w, height: h * 0.10), green)
            ctx.box(CGRect(x: 0, y: h * 0.10, width: w, height: max(2, h * 0.008)),
                    mix(green, Palette.carrara, 0.45))

            for b in 0...bays {
                let x = pitch * CGFloat(b)
                ctx.box(CGRect(x: x - w * 0.008, y: 0, width: w * 0.016, height: h * 0.86),
                        mix(Palette.carrara, green, 0.24))
            }

            for b in 0..<bays {
                let cx = pitch * (CGFloat(b) + 0.5)
                ctx.opening(archPath(cx: cx, base: h * 0.30, top: h * 0.66, half: pitch * 0.15),
                            fill: Palette.recess,
                            jambs: [(mix(Palette.carrara, Palette.rose, 0.25), pitch * 0.075),
                                    (green, pitch * 0.026)])
                // An oculus above each window: the flank's only circular figure, and what stops
                // 58 m of horizontal banding from reading as corduroy.
                let oc = CGPoint(x: cx, y: h * 0.755)
                ctx.circle(centre: oc, radius: pitch * 0.075, green, max(2, pitch * 0.022))
                ctx.disc(centre: oc, radius: pitch * 0.052,
                         mix(Palette.recess, Palette.carrara, 0.30))
            }

            ctx.box(CGRect(x: 0, y: h * 0.865, width: w, height: h * 0.030), green)
            ctx.box(CGRect(x: 0, y: h * 0.910, width: w, height: h * 0.045),
                    mix(Palette.carrara, Palette.stucco, 0.22))
            ctx.box(CGRect(x: 0, y: h * 0.970, width: w, height: h * 0.030), Palette.rose)
        }
    }
}

// MARK: - drawing helpers

/// Every texture is authored in sRGB, because the palette is written as sRGB hex. Device RGB drifts
/// off it by a few percent, which is enough to pull the green marble grey.
private let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

private func canvas(_ size: CGSize, _ draw: (CGContext) -> Void) -> NSImage {
    let w = max(1, Int(size.width.rounded())), h = max(1, Int(size.height.rounded()))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: srgb,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        return NSImage(size: size)
    }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    draw(ctx)
    guard let cg = ctx.makeImage() else { return NSImage(size: size) }
    return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
}

private func archPath(cx: CGFloat, base: CGFloat, top: CGFloat, half: CGFloat) -> CGPath {
    let spring = max(base, top - half)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx - half, y: base))
    p.addLine(to: CGPoint(x: cx - half, y: spring))
    // y is up in these contexts, so the top half of the circle is the clockwise sweep.
    p.addArc(center: CGPoint(x: cx, y: spring), radius: half, startAngle: .pi, endAngle: 0,
             clockwise: true)
    p.addLine(to: CGPoint(x: cx + half, y: base))
    p.closeSubpath()
    return p
}

private func doorway(_ ctx: CGContext, cx: CGFloat, base: CGFloat, top: CGFloat, half: CGFloat) {
    let spring = max(base, top - half)
    let jamb = half * 0.06

    for side in [-1, 1] as [CGFloat] {
        let outer = cx + side * half, inner = cx + side * jamb
        let leaf = CGRect(x: min(outer, inner), y: base,
                          width: abs(outer - inner), height: spring - base)
        ctx.box(leaf, Tex.Palette.bronze)
        // Panels in a 2 × 5 grid, the arrangement every bronze door in Florence uses. Each is a
        // lit top-left edge over a darker field, which is all relief is at this distance.
        let rows = 5, cols = 2
        let cw = leaf.width / CGFloat(cols), ch = leaf.height / CGFloat(rows)
        for r in 0..<rows {
            for c in 0..<cols {
                let cell = CGRect(x: leaf.minX + cw * CGFloat(c), y: leaf.minY + ch * CGFloat(r),
                                  width: cw, height: ch).insetBy(dx: cw * 0.13, dy: ch * 0.13)
                ctx.box(cell, mix(Tex.Palette.bronze, Tex.Palette.gilt, 0.30))
                ctx.box(cell.insetBy(dx: cw * 0.06, dy: ch * 0.06),
                        mix(Tex.Palette.bronze, Tex.Palette.black, 0.35))
            }
        }
    }
    ctx.box(CGRect(x: cx - jamb, y: base, width: jamb * 2, height: spring - base),
            mix(Tex.Palette.bronze, Tex.Palette.gilt, 0.45))

    ctx.saveGState()
    ctx.addPath(archPath(cx: cx, base: spring, top: top, half: half))
    ctx.clip()
    ctx.box(CGRect(x: cx - half, y: spring, width: half * 2, height: half * 1.1),
            mix(Tex.Palette.gilt, Tex.Palette.rose, 0.30))
    ctx.spokes(centre: CGPoint(x: cx, y: spring), radius: half,
               count: 14, mix(Tex.Palette.gilt, Tex.Palette.recess, 0.45), max(1.5, half * 0.02))
    ctx.disc(centre: CGPoint(x: cx, y: spring + half * 0.30), radius: half * 0.22,
             mix(Tex.Palette.recess, Tex.Palette.rose, 0.35))
    ctx.restoreGState()
}

private func courses(_ ctx: CGContext, _ size: CGSize, count: Int) {
    let n = max(1, count)
    let band = size.height / CGFloat(n)
    for i in 0..<n where i % 2 == 1 {
        ctx.box(CGRect(x: 0, y: band * CGFloat(i), width: size.width, height: band * 0.58),
                Tex.Palette.prato)
        ctx.box(CGRect(x: 0, y: band * CGFloat(i) + band * 0.58, width: size.width,
                       height: max(1.5, band * 0.14)), Tex.Palette.rose)
    }
}

private extension CGContext {
    func box(_ r: CGRect, _ c: NSColor) {
        setFillColor(c.cgColor)
        fill(r)
    }

    func frame(_ r: CGRect, _ c: NSColor, _ lineWidth: CGFloat) {
        setStrokeColor(c.cgColor)
        setLineWidth(lineWidth)
        stroke(r.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
    }

    func opening(_ path: CGPath, fill: NSColor, jambs: [(NSColor, CGFloat)] = []) {
        saveGState()
        setLineJoin(.round)
        for (color, width) in jambs {
            addPath(path)
            setLineWidth(width)
            setStrokeColor(color.cgColor)
            strokePath()
        }
        addPath(path)
        setFillColor(fill.cgColor)
        fillPath()
        restoreGState()
    }

    func circle(centre: CGPoint, radius: CGFloat, _ c: NSColor, _ lineWidth: CGFloat) {
        saveGState()
        setStrokeColor(c.cgColor)
        setLineWidth(lineWidth)
        strokeEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                 width: radius * 2, height: radius * 2))
        restoreGState()
    }

    func disc(centre: CGPoint, radius: CGFloat, _ c: NSColor) {
        setFillColor(c.cgColor)
        fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                               width: radius * 2, height: radius * 2))
    }

    /// Radial bars: the tracery of a rose window, which at this distance is all a rose window is.
    func spokes(centre: CGPoint, radius: CGFloat, count: Int, _ c: NSColor, _ lineWidth: CGFloat) {
        let n = max(1, count)
        saveGState()
        setStrokeColor(c.cgColor)
        setLineWidth(lineWidth)
        for i in 0..<n {
            let a = 2 * CGFloat.pi * CGFloat(i) / CGFloat(n)
            move(to: centre)
            addLine(to: CGPoint(x: centre.x + cos(a) * radius, y: centre.y + sin(a) * radius))
        }
        strokePath()
        restoreGState()
    }

    /// A diamond inscribed in `r`: the revetment's stock figure, and the only non-rectilinear motif
    /// that survives being read from 30 m up a tower.
    func lozenge(_ r: CGRect, _ c: NSColor, _ lineWidth: CGFloat) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.midY))
        p.closeSubpath()
        saveGState()
        addPath(p)
        setStrokeColor(c.cgColor)
        setLineWidth(lineWidth)
        strokePath()
        restoreGState()
    }
}

/// An image straight from a pixel buffer. Unlike a bitmap context, a CGImage built on a data
/// provider has an unambiguous row order: row 0 is the top.
private func bitmap(_ rgbx: [UInt8], _ n: Int) -> NSImage? {
    guard let data = CFDataCreate(nil, rgbx, rgbx.count),
          let provider = CGDataProvider(data: data),
          let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: n * 4, space: srgb,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true,
                           intent: .defaultIntent) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: n, height: n))
}

private func blend(_ a: UInt8, _ to: Double, _ t: Double) -> UInt8 {
    UInt8(max(0, min(255, Double(a) + (to - Double(a)) * t)))
}

/// `sky()` lays it out down an image, `skyCube()` evaluates it per direction.
private let skyStops: [(CGFloat, NSColor)] = [
    (0.00, Tex.Palette.skyZenith),
    (0.34, mix(Tex.Palette.skyZenith, Tex.Palette.skyHorizon, 0.45)),
    (0.50, Tex.Palette.skyHorizon),
    (1.00, mix(Tex.Palette.skyHorizon, Tex.Palette.ground, 0.60)),
]

private let skyRamp: [(CGFloat, (CGFloat, CGFloat, CGFloat))] = skyStops.map { stop in
    let c = stop.1.usingColorSpace(.sRGB) ?? stop.1
    return (stop.0, (c.redComponent, c.greenComponent, c.blueComponent))
}

private func skyColor(at position: CGFloat) -> (UInt8, UInt8, UInt8) {
    let t = min(max(position, 0), 1)
    var lo = skyRamp[0], hi = skyRamp[skyRamp.count - 1]
    for i in 1..<skyRamp.count where skyRamp[i].0 >= t {
        lo = skyRamp[i - 1]
        hi = skyRamp[i]
        break
    }
    let f = (t - lo.0) / max(1e-6, hi.0 - lo.0)
    func channel(_ x: CGFloat, _ y: CGFloat) -> UInt8 {
        UInt8(max(0, min(255, (x + (y - x) * f) * 255)))
    }
    return (channel(lo.1.0, hi.1.0), channel(lo.1.1, hi.1.1), channel(lo.1.2, hi.1.2))
}


private func veining(_ ctx: CGContext, _ size: CGSize, seed: UInt64) {
    var rng = Seeded(seed)
    ctx.saveGState()
    ctx.setLineCap(.round)
    for _ in 0..<16 {
        let p = CGMutablePath()
        var x = size.width * .random(in: -0.2...0.2, using: &rng)
        var y = size.height * .random(in: 0...1, using: &rng)
        p.move(to: CGPoint(x: x, y: y))
        for _ in 0..<6 {
            x += size.width * .random(in: 0.12...0.30, using: &rng)
            y += size.height * .random(in: -0.05...0.05, using: &rng)
            p.addLine(to: CGPoint(x: x, y: y))
        }
        ctx.addPath(p)
        ctx.setStrokeColor(NSColor(srgbRed: 0.60, green: 0.58, blue: 0.54,
                                   alpha: .random(in: 0.04...0.10, using: &rng)).cgColor)
        ctx.setLineWidth(max(1.5, size.width * .random(in: 0.002...0.005, using: &rng)))
        ctx.strokePath()
    }
    ctx.restoreGState()
}

private func grain(_ ctx: CGContext, _ size: CGSize, seed: UInt64) {
    var rng = Seeded(0x57DCC0 &+ seed)
    let cs = srgb
    for _ in 0..<40 {
        let p = CGPoint(x: .random(in: 0...size.width, using: &rng),
                        y: .random(in: 0...size.height, using: &rng))
        let r = size.width * .random(in: 0.06...0.22, using: &rng)
        let c = mix(Tex.Palette.stucco,
                    Bool.random(using: &rng) ? Tex.Palette.white : Tex.Palette.black,
                    .random(in: 0.04...0.11, using: &rng))
        guard let g = CGGradient(colorsSpace: cs,
                                 colors: [c.withAlphaComponent(0.5).cgColor,
                                          c.withAlphaComponent(0).cgColor] as CFArray,
                                 locations: [0, 1]) else { continue }
        ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: r,
                               options: [])
    }
}

/// Deterministic: the same piazza every launch, so two `--shot` renders differ only by the pose.
private struct Seeded: RandomNumberGenerator {
    private var state: UInt64

    init(_ seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
