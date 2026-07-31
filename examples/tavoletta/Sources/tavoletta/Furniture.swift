// The things standing on the pavement between the viewer and the Baptistery.
//
// Everything here exists for one reason: an unbroken paved plane has no scale. A column at 21 m and
// a wellhead at 34 m give the eye two intermediate rungs between the marble bands underfoot and the
// architecture at the far end, and — more useful still — they *occlude*, which a painted plane
// cannot. Their shadows do as much work as their masses.
//
// Frame is the piazza frame throughout: Z up, pavement at z = 0, +Y toward the Baptistery. Each
// piece is built about its own footprint centre at z = 0 and left there; the caller positions it.
//
// SceneKit's SCNCylinder, SCNCone, SCNTube and SCNPlane are all born about the *y* axis, so every
// one of them below carries `standUp`. SCNBox is axis-aligned and needs nothing.
import AppKit
import SceneKit
import simd

/// Mid-ground pieces: the things that make 15 to 40 metres of pavement read as distance rather
/// than as an empty surface. All returned nodes are built in the piazza frame — Z up, pavement
/// at z = 0 — and are positioned by the caller unless stated otherwise.
enum Furniture {

    // MARK: - column

    /// A granite column on a stepped base with a bronze figure on top. `height` is pavement to
    /// the top of the figure. Fluted shaft, simple capital.
    ///
    /// Proportions are fractions of `height` rather than fixed metres, so the piece stays a column
    /// and not a bollard or a mast whatever the caller asks for. They are set for the Florentine
    /// type — the Colonna della Giustizia — which is stouter than a classical order: about six and
    /// a third diameters of shaft over a broad two-step base.
    static func column(height h: Double) -> SCNNode {
        let group = SCNNode()
        group.name = "column"

        let shaftR = 0.048 * h
        let figureH = 0.17 * h
        let capH = 0.055 * h
        let capTop = h - figureH          // the figure stands on the abacus

        let granite = paint(Tex.Palette.granite, roughness: 0.74)
        let worn = paint(mix(Tex.Palette.carrara, Tex.Palette.ground, 0.32), roughness: 0.80)

        // Two square steps and a square dado. A round shaft rising straight out of the paving reads
        // as a pipe; the corners are what say "base", and they are also what catch the sun on one
        // face and lose it on the next, which is how the eye reads the piece as solid.
        var z = 0.0
        let stepRise = 0.026 * h
        for i in 0..<2 {
            let side = shaftR * (5.8 - 1.0 * Double(i))
            group.addChildNode(block(side: side, from: z, to: z + stepRise, worn))
            z += stepRise
        }

        let dadoH = 0.090 * h
        group.addChildNode(block(side: shaftR * 3.4, from: z, to: z + dadoH, granite))
        z += dadoH

        // Torus moulding at the foot of the shaft: an eight-sided cylinder is enough at 21 m, and
        // it hides the joint where the round shaft meets the square dado.
        let torusH = 0.028 * h
        let moulding = SCNCylinder(radius: shaftR * 1.45, height: torusH)
        moulding.radialSegmentCount = 16
        moulding.firstMaterial = granite
        let mouldingNode = SCNNode(geometry: moulding)
        mouldingNode.simdPosition = SIMD3(0, 0, Float(z + torusH / 2))
        mouldingNode.simdOrientation = standUp
        group.addChildNode(mouldingNode)
        z += torusH

        let shaft = SCNNode(geometry: flutedShaft(height: capTop - capH - z,
                                                  bottomRadius: shaftR,
                                                  topRadius: shaftR * 0.86,
                                                  flutes: 20, depth: 0.085, granite))
        shaft.simdPosition = SIMD3(0, 0, Float(z))   // the mesh is built from its own z = 0 up
        group.addChildNode(shaft)

        // Echinus: a cone frustum that flares *outward* going up, so topRadius exceeds bottomRadius.
        let echinusH = capH * 0.6
        let echinus = SCNCone(topRadius: shaftR * 1.5, bottomRadius: shaftR * 0.88, height: echinusH)
        echinus.radialSegmentCount = 24
        echinus.firstMaterial = granite
        let echinusNode = SCNNode(geometry: echinus)
        echinusNode.simdPosition = SIMD3(0, 0, Float(capTop - capH + echinusH / 2))
        echinusNode.simdOrientation = standUp
        group.addChildNode(echinusNode)

        group.addChildNode(block(side: shaftR * 3.0, from: capTop - capH + echinusH, to: capTop,
                                 granite))
        group.addChildNode(figure(scale: figureH, base: capTop))
        return group
    }

    /// A standing bronze, built from limbs rather than a mesh: at 21 m what carries is the
    /// silhouette — one arm down, one arm up with a staff — and eight capsules give that for eight
    /// nodes. It faces -Y, back down the piazza at the viewing station.
    ///
    /// `scale` is the full pavement-relative height of the figure and every dimension is a fraction
    /// of it, so the staff's tip lands exactly on `base + scale`.
    private static func figure(scale s: Double, base z0: Double) -> SCNNode {
        let group = SCNNode()
        group.name = "figure"
        let metal = paint(Tex.Palette.bronze, roughness: 0.42, metalness: 0.75)

        func p(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Double> {
            SIMD3(x * s, y * s, z0 + z * s)
        }
        for side in [-1.0, 1.0] {
            group.addChildNode(bar(p(side * 0.10, 0.02, 0.00), p(side * 0.06, 0, 0.46),
                                   radius: 0.055 * s, metal))
        }
        group.addChildNode(bar(p(0, 0, 0.42), p(0, -0.02, 0.76), radius: 0.115 * s, metal))
        group.addChildNode(bar(p(-0.15, -0.02, 0.74), p(0.15, -0.02, 0.74),
                               radius: 0.055 * s, metal))

        let head = SCNSphere(radius: 0.085 * s)
        head.segmentCount = 16
        head.firstMaterial = metal
        let headNode = SCNNode(geometry: head)
        headNode.simdPosition = float3(p(0, -0.03, 0.86))
        group.addChildNode(headNode)

        group.addChildNode(bar(p(0.15, -0.02, 0.74), p(0.30, -0.06, 0.96), radius: 0.045 * s, metal))
        group.addChildNode(bar(p(-0.15, -0.02, 0.73), p(-0.19, -0.10, 0.40),
                               radius: 0.045 * s, metal))
        group.addChildNode(bar(p(0.31, -0.06, 0.55), p(0.31, -0.06, 1.00), radius: 0.020 * s, metal))
        return group
    }

    // MARK: - wellhead

    /// A Florentine wellhead: an octagonal marble kerb about 1.6 m across and 0.9 m tall, with a
    /// wrought-iron arch and pulley over it.
    ///
    /// The ironwork is the point. The marble alone is a 0.9 m lump that disappears against the
    /// paving at 34 m; the arch stands 2 m and draws a thin dark curve against the far side of the
    /// piazza, which is what makes the distance between them visible.
    static func wellhead() -> SCNNode {
        let group = SCNNode()
        group.name = "wellhead"

        let apothem = 0.80                       // 1.6 m across the flats
        let circumradius = apothem / cos(Double.pi / 8)
        let marble = paint(mix(Tex.Palette.carrara, Tex.Palette.ground, 0.28), roughness: 0.70)
        let iron = paint(Tex.Palette.iron, roughness: 0.55, metalness: 0.35)

        // SCNTube, not SCNCylinder: the mouth has to be a hole. A dark disc laid on a solid top
        // would be right only from directly above, and this is seen from 1.6 m off the ground.
        let kerb = SCNTube(innerRadius: 0.58, outerRadius: circumradius, height: 0.80)
        kerb.radialSegmentCount = 8
        kerb.firstMaterial = marble
        let kerbNode = SCNNode(geometry: kerb)
        kerbNode.simdPosition = SIMD3(0, 0, 0.40)
        kerbNode.simdOrientation = standUp
        group.addChildNode(kerbNode)

        let coping = SCNTube(innerRadius: 0.56, outerRadius: circumradius + 0.07, height: 0.10)
        coping.radialSegmentCount = 8
        coping.firstMaterial = paint(Tex.Palette.carrara, roughness: 0.55)
        let copingNode = SCNNode(geometry: coping)
        copingNode.simdPosition = SIMD3(0, 0, 0.85)
        copingNode.simdOrientation = standUp
        group.addChildNode(copingNode)

        // Plugs the tube 0.4 m below the rim so the opening reads as depth rather than as a
        // window through the piece.
        let shaftFloor = SCNCylinder(radius: 0.575, height: 0.50)
        shaftFloor.radialSegmentCount = 8
        shaftFloor.firstMaterial = paint(Tex.Palette.wellShaft, roughness: 0.95)
        let shaftNode = SCNNode(geometry: shaftFloor)
        shaftNode.simdPosition = SIMD3(0, 0, 0.25)
        shaftNode.simdOrientation = standUp
        group.addChildNode(shaftNode)

        // Semicircular arch on two short uprights socketed into the coping.
        let spring = 1.15, archR = 0.80, segments = 8
        for side in [-1.0, 1.0] {
            group.addChildNode(bar(SIMD3(side * archR, 0, 0.78), SIMD3(side * archR, 0, spring),
                                   radius: 0.035, iron))
        }
        for i in 0..<segments {
            let a0 = Double.pi * Double(i) / Double(segments)
            let a1 = Double.pi * Double(i + 1) / Double(segments)
            group.addChildNode(bar(SIMD3(cos(a0) * archR, 0, spring + sin(a0) * archR),
                                   SIMD3(cos(a1) * archR, 0, spring + sin(a1) * archR),
                                   radius: 0.035, iron))
        }

        // SCNTorus lies in its own xz plane already, which here is the plane of the arch — so the
        // pulley is the one primitive in this file that must *not* be stood up.
        let pulley = SCNTorus(ringRadius: 0.10, pipeRadius: 0.028)
        pulley.ringSegmentCount = 16
        pulley.pipeSegmentCount = 8
        pulley.firstMaterial = iron
        let pulleyNode = SCNNode(geometry: pulley)
        pulleyNode.simdPosition = SIMD3(0, 0, 1.80)
        group.addChildNode(pulleyNode)

        group.addChildNode(bar(SIMD3(0, 0, 1.95), SIMD3(0, 0, 1.80), radius: 0.020, iron))

        let rope = paint(mix(Tex.Palette.ground, Tex.Palette.carrara, 0.25), roughness: 0.95)
        group.addChildNode(bar(SIMD3(0, 0, 1.80), SIMD3(0, 0, 1.31), radius: 0.012, rope))

        let bucket = SCNCylinder(radius: 0.13, height: 0.26)
        bucket.radialSegmentCount = 12
        bucket.firstMaterial = iron
        let bucketNode = SCNNode(geometry: bucket)
        bucketNode.simdPosition = SIMD3(0, 0, 1.18)
        bucketNode.simdOrientation = standUp
        group.addChildNode(bucketNode)
        return group
    }

    // MARK: - kerb ring

    /// A low continuous kerb ring, `radius` across, `count` segments, ~0.35 m tall and 0.5 m
    /// wide, in the same marble as the pavement bands. Returns one node centred on the origin.
    ///
    /// One mesh, not `count` boxes: a 21 m ring wants forty-odd segments to stop looking like a
    /// stop sign, and forty nodes for a kerb is forty nodes the rest of the piazza needs more.
    /// Only the top and the two walls are built — the underside is on the pavement.
    static func kerbRing(radius: Double, count: Int) -> SCNNode {
        let n = max(3, count)
        let top = 0.35, half = 0.25
        let ro = radius + half, ri = radius - half
        var faces: [[SIMD3<Double>]] = []

        for i in 0..<n {
            let a0 = 2 * Double.pi * Double(i) / Double(n)
            let a1 = 2 * Double.pi * Double(i + 1) / Double(n)
            func at(_ a: Double, _ r: Double, _ z: Double) -> SIMD3<Double> {
                SIMD3(cos(a) * r, sin(a) * r, z)
            }
            // Wound so each normal points away from the marble: up, outward, inward.
            faces.append([at(a0, ro, top), at(a1, ro, top), at(a1, ri, top), at(a0, ri, top)])
            faces.append([at(a0, ro, 0), at(a1, ro, 0), at(a1, ro, top), at(a0, ro, top)])
            faces.append([at(a1, ri, 0), at(a0, ri, 0), at(a0, ri, top), at(a1, ri, top)])
        }

        let node = SCNNode(geometry: flatMesh(faces, paint(Tex.Palette.band, roughness: 0.62)))
        node.name = "kerb-ring"
        return node
    }

    // MARK: - steps

    /// A flight of `steps` risers, each `rise` tall and `tread` deep, running the full `width`,
    /// centred on x = 0 with the bottom riser's outer face at y = 0 and climbing toward +Y.
    ///
    /// Each step is a full-height box from the pavement up rather than a slab sitting on the one
    /// below, so no two faces are ever coplanar at the front and the risers cannot z-fight; the
    /// buried volume costs nothing.
    static func steps(width: Double, steps: Int, rise: Double, tread: Double) -> SCNNode {
        let group = SCNNode()
        group.name = "steps"
        let n = max(1, steps)
        let run = Double(n) * tread
        let stone = paint(mix(Tex.Palette.carrara, Tex.Palette.ground, 0.30), roughness: 0.78)

        for i in 0..<n {
            let front = Double(i) * tread
            // The backs are staggered by 4 mm apiece for the same reason: they are flush otherwise,
            // and a stylobate seen from the flank shows the fight.
            let back = run + Double(i) * 0.004
            let height = Double(i + 1) * rise
            // And the flanks by 3 mm apiece, for the same reason again: staggering the backs
            // leaves every riser exactly `width` across, so all n side faces stay coplanar and the
            // flight z-fights down its own edge from any oblique angle.
            let box = SCNBox(width: width - Double(i) * 0.006, height: back - front,
                             length: height, chamferRadius: 0)
            box.firstMaterial = stone
            let node = SCNNode(geometry: box)
            node.simdPosition = SIMD3(0, Float((front + back) / 2), Float(height / 2))
            group.addChildNode(node)
        }
        return group
    }

    // MARK: - construction helpers

    /// SCNCylinder, SCNCone, SCNTube and SCNPlane are born about SceneKit's +Y. This puts their
    /// axis on the piazza's +Z.

    /// A square block spanning `from`...`to` in z, centred on the origin in plan.
    private static func block(side: Double, from z0: Double, to z1: Double,
                              _ material: SCNMaterial) -> SCNNode {
        let box = SCNBox(width: side, height: side, length: z1 - z0, chamferRadius: 0)
        box.firstMaterial = material
        let node = SCNNode(geometry: box)
        node.simdPosition = SIMD3(0, 0, Float((z0 + z1) / 2))
        return node
    }

    /// A cylinder running from `a` to `b`: everything in this file that is a line rather than a
    /// mass — iron, rope, limbs — is one of these.
    private static func bar(_ a: SIMD3<Double>, _ b: SIMD3<Double>, radius: Double,
                            _ material: SCNMaterial) -> SCNNode {
        let d = b - a
        let length = simd_length(d)
        let cylinder = SCNCylinder(radius: radius, height: max(length, 1e-4))
        cylinder.radialSegmentCount = 10
        cylinder.firstMaterial = material
        let node = SCNNode(geometry: cylinder)
        node.simdPosition = float3((a + b) / 2)
        guard length > 1e-6 else { return node }

        // `simd_quatf(from:to:)` is undefined for exactly opposed vectors, and a rope hanging
        // straight down is exactly opposed to the cylinder's +Y, so that case is turned by hand.
        let up = SIMD3<Float>(0, 1, 0)
        let along = simd_normalize(float3(d))
        node.simdOrientation = simd_dot(along, up) < -0.9999
            ? simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
            : simd_quatf(from: up, to: along)
        return node
    }

    /// A shaft with `flutes` hollows run down it, as a single mesh — twenty grooves modelled as
    /// nodes would cost more than every other piece here put together.
    ///
    /// The section's radius dips to `depth` of full at the middle of each flute and returns to full
    /// at the arris between them, so the silhouette keeps a clean edge and the late-morning sun
    /// rakes twenty verticals down the shaft. `topRadius` under `bottomRadius` gives the taper.
    private static func flutedShaft(height: Double, bottomRadius: Double, topRadius: Double,
                                    flutes: Int, depth: Double,
                                    _ material: SCNMaterial) -> SCNGeometry {
        let perFlute = 6, rings = 4
        let n = flutes * perFlute
        let scallop = (0..<n).map { j in
            1 - depth * sin(Double.pi * Double(j % perFlute) / Double(perFlute))
        }
        func at(_ j: Int, _ z: Double) -> SIMD3<Double> {
            let a = 2 * Double.pi * Double(j % n) / Double(n)
            let r = (bottomRadius + (topRadius - bottomRadius) * (z / height)) * scallop[j % n]
            return SIMD3(cos(a) * r, sin(a) * r, z)
        }

        var faces: [[SIMD3<Double>]] = []
        for k in 0..<rings {
            let z0 = height * Double(k) / Double(rings)
            let z1 = height * Double(k + 1) / Double(rings)
            for j in 0..<n {
                faces.append([at(j, z0), at(j + 1, z0), at(j + 1, z1), at(j, z1)])
            }
        }
        return flatMesh(faces, material)
    }

}
