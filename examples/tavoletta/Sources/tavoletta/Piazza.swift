// Piazza del Duomo, built once and never moved.
//
// The frame here is the piazza frame: origin at the viewing station on the pavement, +Y toward the
// Baptistery, +Z up, pavement at z = 0. It matches wabe's world frame in handedness and units, so
// re-anchoring is a rigid transform on the single node `build()` hands back — nothing in this file
// needs to know where the laptop is.
//
// The station is a few metres out from the central door of Santa Maria del Fiore, which is where
// Brunelleschi stood. Everything is placed to make that a *place* rather than a backdrop, and the
// three things that do that are worth naming because they are the only reason most of these numbers
// are what they are:
//
//   depth      — something at 5 m, 21 m, 23 m, 34 m, 65 m, 86 m and 104 m, in the same frame
//   occlusion  — the column in front of the campanile, the campanile in front of the palazzi,
//                the kerb ring in front of the Baptistery's steps
//   enclosure  — architecture in every direction and taller than the frame, so tipping the lid
//                crops a building instead of finding sky
//
// SceneKit's primitives are y-up, which our frame is not. Everything that comes out of SCNPlane,
// SCNCylinder or SCNCone therefore carries an explicit stand-up rotation about X. A building lying
// on its side is the classic failure here, so the rotation is applied in one place per primitive
// kind rather than sprinkled at call sites.
import AppKit
import SceneKit
import simd

enum Piazza {
    static let baptisteryDistance = 86.0 // piazza-frame +Y to the Baptistery's centre
    static let baptisteryAcrossFlats = 25.6
    static let baptisteryHeight = 31.0   // pavement to the tip of the lantern

    /// Width of a marble band, and how far it stands proud of the surrounding pavement.
    static let bandWidth = 0.45
    static let bandRise = 0.02

    /// The pavement's marble bands, as world-frame (piazza-frame) segments, so the overlay can
    /// trace the exact lines the renderer drew. Both arrays are in piazza coordinates at z = 0.
    ///
    /// These are not a description of the geometry, they are its source: `build()` extrudes each
    /// segment into the box that gets drawn. The construction lines land on the marble because
    /// they are computed from the same numbers, not because the numbers were copied correctly.
    ///
    /// The two extents agree at the corner — 8 × 4.4 = 35.2 — so the grid closes rather than
    /// fraying, which matters because a half-drawn transversal reads as a bug in the projection.
    static let orthogonals: [(SIMD3<Double>, SIMD3<Double>)] = (-8...8).map { k in
        let x = Double(k) * 4.4
        // Runs well behind the station, not just ahead of it. The mirror shows what is behind
        // you, so a grid laid only in front is a grid the demo never sees.
        return (SIMD3<Double>(x, -44, 0), SIMD3<Double>(x, 56, 0))
    }

    static let transversals: [(SIMD3<Double>, SIMD3<Double>)] = (-8...10).map { j in
        let y = Double(j) * 5.5
        return (SIMD3<Double>(-35.2, y, 0), SIMD3<Double>(35.2, y, 0))
    }

    /// Builds the scene in the piazza frame and returns both it and the node everything hangs
    /// from — the caller re-anchors that node into world coordinates at recenter.
    static func build() -> (scene: SCNScene, world: SCNNode) {
        let scene = SCNScene()
        scene.background.contents = Tex.skyCube(sun: sunDirection)
        // The sky is also the scene's other light: PBR stone lit by one sun and a flat ambient
        // term goes chalky. Kept low, because it competes with the sun and the sun is what draws
        // the shadows the perspective is read from.
        //
        // Its own copy of the cube, deliberately: SceneKit convolves whatever it is handed here
        // into an irradiance map, and handing it the same array as the background replaces the
        // background with the blurred version — a flat cream sky with no gradient at all.
        scene.lightingEnvironment.contents = Tex.skyCube(sun: sunDirection)
        scene.lightingEnvironment.intensity = 0.40

        let world = SCNNode()
        world.name = "piazza"
        scene.rootNode.addChildNode(world)

        buildPavement(into: world)
        buildCampanile(into: world)
        buildBaptistery(into: world)
        buildDuomo(into: world)
        buildPalazzi(into: world)
        buildFurniture(into: world)
        buildLighting(into: world)
        buildSun(into: world)

        // Culling is left alone on purpose. The mirror's transform has determinant -1, which is
        // the kind of thing that looks like it must flip which face is front — it does not here,
        // and overriding cullMode to .front hides every facade in the piazza while leaving the
        // pavement and the construction lines in place, so the demo still looks like a demo.
        return (scene, world)
    }

    // MARK: - pavement

    /// Ground plane extents. Far wider than the paved grid, because the palazzi stand at x = ±37
    /// and the campanile's shadow runs 50 m off to the right of everything.
    private static let groundX = 90.0
    private static let groundY = (near: -60.0, far: 170.0)

    private static func buildPavement(into parent: SCNNode) {
        let field = stone(Tex.pavement(size: CGSize(width: 512, height: 512)), roughness: 0.88)
        field.diffuse.wrapS = .repeat
        field.diffuse.wrapT = .repeat
        let width = groundX * 2, depth = groundY.far - groundY.near
        field.diffuse.contentsTransform = SCNMatrix4MakeScale(CGFloat(width / 4),
                                                              CGFloat(depth / 4), 1)  // 4 m a tile
        field.diffuse.maxAnisotropy = 8
        let thickness = 0.30
        let box = SCNBox(width: width, height: depth, length: thickness, chamferRadius: 0)
        box.firstMaterial = field
        let ground = SCNNode(geometry: box)
        // Top face at z = -bandRise, so the *bands* — the surfaces the construction lines have to
        // land on — sit at exactly z = 0 while still standing proud of the pavement around them.
        ground.simdPosition = float3(SIMD3(0, (groundY.far + groundY.near) / 2,
                                           -bandRise - thickness / 2))
        parent.addChildNode(ground)

        let marble = paint(Tex.Palette.band, roughness: 0.32)
        for (a, b) in orthogonals + transversals {
            let d = b - a
            let along = simd_length(d)
            let acrossX = abs(d.x) > abs(d.y)
            let box = SCNBox(width: acrossX ? along : bandWidth,
                             height: acrossX ? bandWidth : along,
                             length: bandRise, chamferRadius: 0)
            box.firstMaterial = marble
            let node = SCNNode(geometry: box)
            node.simdPosition = float3((a + b) / 2 - SIMD3(0, 0, bandRise / 2))
            node.castsShadow = false  // 2 cm of relief, and the shadow map has better uses
            parent.addChildNode(node)
        }
    }

    // MARK: - Giotto's campanile
    //
    // The most important object in the scene, and the one the first version did not have. 14.5 m
    // square, 85 m tall, its near corner 21 m from the eye: it fills the right-hand side of the
    // frame from the pavement clean out of the top, occludes the palazzi behind it, and is the only
    // thing here that rewards tipping the lid up. Near, enormous, and in the way — which is what a
    // rendered view needs before it reads as a space instead of a surface.

    private static let campanileCentre = SIMD3<Double>(17, 26, 0)
    private static let campanileSide = 14.5

    /// The shaft's four revetment registers and the cornice that caps each, pavement upward.
    /// A table because the index also picks the texture, and because the cornice heights are the
    /// only thing keeping 85 m of wall from being one undivided slab.
    private static let campanileRegisters: [(z0: Double, z1: Double, cornice: Double)] = [
        (2.0, 21.5, 1.2), (22.7, 41.0, 1.2), (42.2, 60.5, 1.2), (61.7, 81.0, 1.6),
    ]

    private static func buildCampanile(into parent: SCNNode) {
        let c = campanileCentre
        let half = campanileSide / 2
        let top = 85.0

        // Solid core the full height: the four face quads are single-sided, and at grazing angles
        // a hollow shaft shows daylight through its own corners.
        let core = SCNBox(width: campanileSide, height: campanileSide, length: top,
                          chamferRadius: 0)
        core.firstMaterial = paint(mix(Tex.Palette.carrara, Tex.Palette.stucco, 0.30),
                                   roughness: 0.7)
        let coreNode = SCNNode(geometry: core)
        coreNode.simdPosition = float3(c + SIMD3(0, 0, top / 2))
        parent.addChildNode(coreNode)

        let plinth = paint(mix(Tex.Palette.carrara, Tex.Palette.ground, 0.35), roughness: 0.8)
        parent.addChildNode(slab(at: c + SIMD3(0, 0, 1.0), size: SIMD3(campanileSide + 1.2,
                                                                      campanileSide + 1.2, 2.0),
                                 plinth))

        let trim = paint(mix(Tex.Palette.carrara, Tex.Palette.ground, 0.15), roughness: 0.6)
        for (i, r) in campanileRegisters.enumerated() {
            let h = r.z1 - r.z0
            let px = 512.0
            let image = Tex.campanile(register: i,
                                      size: CGSize(width: px,
                                                   height: (px * h / campanileSide).rounded()))
            let face = stone(image, roughness: 0.45)
            for k in 0..<4 {
                let (azimuth, outward) = polyFace(k, sides: 4)
                let p = c + outward * (half + 0.02) + SIMD3(0, 0, (r.z0 + r.z1) / 2)
                parent.addChildNode(facade(face, campanileSide, h, at: p, azimuth: azimuth))
            }
            // One box per cornice rather than four mitred ones: a square needs no mitre, and these
            // are the horizontals the whole right-hand side of the picture is measured against.
            parent.addChildNode(slab(at: c + SIMD3(0, 0, r.z1 + r.cornice / 2),
                                     size: SIMD3(campanileSide + 1.6, campanileSide + 1.6,
                                                 r.cornice),
                                     trim))
        }

        // Terrace at the top. It is 85 m up and almost never in frame, but when the lid tips back
        // far enough the tower has to end in something.
        let last = campanileRegisters[campanileRegisters.count - 1]
        let parapetZ = last.z1 + last.cornice
        parent.addChildNode(slab(at: c + SIMD3(0, 0, (parapetZ + top) / 2),
                                 size: SIMD3(campanileSide + 1.0, campanileSide + 1.0,
                                             top - parapetZ),
                                 paint(mix(Tex.Palette.carrara, Tex.Palette.prato, 0.20),
                                       roughness: 0.65)))
    }

    // MARK: - the Baptistery of San Giovanni

    private static func buildBaptistery(into parent: SCNNode) {
        let centre = SIMD3<Double>(0, baptisteryDistance, 0)
        let apothem = baptisteryAcrossFlats / 2
        let side = 2 * apothem * tan(.pi / 8)

        // Three-step stylobate, 30 m across the flats and 1.2 m proud. The steps are what tie the
        // building to the ground; without them an octagon on a flat plane reads as a decal.
        let stepStone = paint(mix(Tex.Palette.carrara, Tex.Palette.ground, 0.35), roughness: 0.8)
        for step in [(apothem: 15.0, z0: 0.00, z1: 0.40, depth: 1.4),
                     (apothem: 14.3, z0: 0.40, z1: 0.80, depth: 1.0),
                     (apothem: 13.6, z0: 0.80, z1: 1.20, depth: 1.0)] {
            parent.addChildNode(polyBand(centre: centre, sides: 8, apothem: step.apothem,
                                         z0: step.z0, z1: step.z1, depth: step.depth, stepStone))
        }

        let plinth = 1.20, cornice = 21.0, eaves = 22.2, lanternFloor = 27.2

        // Solid core behind the revetment, for the same reason as the campanile's.
        let core = SCNCylinder(radius: apothem * 0.97, height: cornice - plinth)
        core.radialSegmentCount = 8
        core.firstMaterial = paint(mix(Tex.Palette.carrara, Tex.Palette.stucco, 0.4), roughness: 0.9)
        let coreNode = SCNNode(geometry: core)
        coreNode.simdPosition = float3(centre + SIMD3(0, 0, (plinth + cornice) / 2))
        coreNode.simdOrientation = standUp
        parent.addChildNode(coreNode)

        let tiers: [(z0: Double, z1: Double)] = [(plinth, 9.6), (9.6, 16.8), (16.8, cornice)]
        for (i, tier) in tiers.enumerated() {
            let h = tier.z1 - tier.z0
            let px = 512.0
            let image = Tex.revetment(tier: i, size: CGSize(width: px,
                                                            height: (px * h / side).rounded()))
            let face = stone(image, roughness: 0.42)
            for k in 0..<8 {
                let (azimuth, outward) = polyFace(k, sides: 8)
                let p = centre + outward * (apothem + 0.01) + SIMD3(0, 0, (tier.z0 + tier.z1) / 2)
                parent.addChildNode(facade(face, side, h, at: p, azimuth: azimuth))
            }
        }

        let pale = paint(mix(Tex.Palette.carrara, Tex.Palette.ground, 0.18), roughness: 0.65)
        parent.addChildNode(polyBand(centre: centre, sides: 8, apothem: apothem + 0.70,
                                     z0: cornice, z1: eaves, depth: 1.5, pale))

        // Pyramidal roof, built by hand: SCNCone's 8-gon starts at an arbitrary azimuth, and a roof
        // whose corners miss the cornice's corners is the first thing the eye notices. Truncated at
        // the lantern floor so the lantern has something to stand on.
        let roof = polyRoof(centre: centre, sides: 8,
                            lower: (radius: (apothem + 0.75) / cos(.pi / 8), z: eaves),
                            upper: (radius: 2.6, z: lanternFloor),
                            paint(Tex.Palette.roofTile, roughness: 0.85))
        parent.addChildNode(roof)

        let white = paint(Tex.Palette.carrara, roughness: 0.5)
        let drum = SCNCylinder(radius: 2.3, height: 2.0)
        drum.radialSegmentCount = 8
        drum.firstMaterial = white
        let drumNode = SCNNode(geometry: drum)
        drumNode.simdPosition = float3(centre + SIMD3(0, 0, lanternFloor + 1.0))
        drumNode.simdOrientation = standUp
        parent.addChildNode(drumNode)

        parent.addChildNode(polyBand(centre: centre, sides: 8, apothem: 2.7,
                                     z0: lanternFloor + 2.0, z1: lanternFloor + 2.4,
                                     depth: 0.5, white))

        // The tip lands on `baptisteryHeight` by construction, not by coincidence.
        let capHeight = baptisteryHeight - (lanternFloor + 2.4)
        let cap = SCNCone(topRadius: 0, bottomRadius: 2.8, height: capHeight)
        cap.radialSegmentCount = 8
        cap.firstMaterial = paint(mix(Tex.Palette.roofTile, Tex.Palette.carrara, 0.25),
                                  roughness: 0.7)
        let capNode = SCNNode(geometry: cap)
        capNode.simdPosition = float3(centre + SIMD3(0, 0, lanternFloor + 2.4 + capHeight / 2))
        capNode.simdOrientation = standUp
        parent.addChildNode(capNode)

        // Bronze doors on the near face. Across that much pavement the eye needs somewhere to land,
        // and this is the face the whole building's azimuth was chosen to present.
        let facePlane = centre.y - apothem
        let gilt = paint(Tex.Palette.gilt, roughness: 0.35, metalness: 0.85)
        parent.addChildNode(facade(gilt, 5.0, 7.2, at: SIMD3(0, facePlane - 0.05, plinth + 3.6),
                                   azimuth: 0))
        let leaf = paint(Tex.Palette.bronze, roughness: 0.45, metalness: 0.7)
        parent.addChildNode(facade(leaf, 4.0, 6.2, at: SIMD3(0, facePlane - 0.10, plinth + 3.2),
                                   azimuth: 0))
    }

    // MARK: - Santa Maria del Fiore

    /// The cathedral the viewer has just walked out of: its west front nine metres behind the
    /// station, its flank running away up the right-hand side. Turning the laptop around is
    /// supposed to be rewarded, and the flank is what makes the turn continuous instead of a cut
    /// between two unrelated pictures.
    private static func buildDuomo(into parent: SCNNode) {
        let marble = paint(mix(Tex.Palette.carrara, Tex.Palette.ground, 0.22), roughness: 0.78)

        // Well back, because the mirror looks this way. At the old 9 m the facade filled the
        // whole reflection with two bronze doors and there was no piazza left to see; at 38 m the
        // full 48 m front stands in the frame with paving in front of it.
        let frontY = -38.0, frontWidth = 60.0, frontHeight = 48.0
        parent.addChildNode(slab(at: SIMD3(0, frontY - 2.5, frontHeight / 2),
                                 size: SIMD3(frontWidth, 5, frontHeight), marble))
        // Twice the pixels of any other wall: this is the only surface the eye ever gets within
        // 9 m of, and at that range a 1024-wide texture puts about 140 px across a bronze door.
        parent.addChildNode(facade(stone(Tex.duomoFacade(size: CGSize(width: 2048, height: 1638)),
                                         roughness: 0.55),
                                   frontWidth, frontHeight,
                                   at: SIMD3(0, frontY + 0.04, frontHeight / 2), azimuth: .pi))

        // Flank: x ∈ [26, 34], y ∈ [-40, 18], 40 m. Its base and cornice run 58 m straight away
        // from the eye, which makes them the fastest-converging lines in the scene — a second
        // family of orthogonals meeting the pavement's at the same point.
        let flankX = 26.0, flankDepth = 8.0
        let y0 = -40.0, y1 = 18.0, flankHeight = 40.0
        let length = y1 - y0, mid = (y0 + y1) / 2
        parent.addChildNode(slab(at: SIMD3(flankX + flankDepth / 2, mid, flankHeight / 2),
                                 size: SIMD3(flankDepth, length, flankHeight), marble))
        parent.addChildNode(facade(stone(Tex.duomoFlank(size: CGSize(width: 1024, height: 706)),
                                         roughness: 0.55),
                                   length, flankHeight,
                                   at: SIMD3(flankX - 0.04, mid, flankHeight / 2),
                                   azimuth: -.pi / 2))
        parent.addChildNode(slab(at: SIMD3(flankX - 0.6, mid, flankHeight - 0.7),
                                 size: SIMD3(1.8, length + 0.6, 1.4),
                                 paint(mix(Tex.Palette.carrara, Tex.Palette.prato, 0.15),
                                       roughness: 0.6)))
        parent.addChildNode(slab(at: SIMD3(flankX - 0.35, mid, 0.55),
                                 size: SIMD3(1.3, length, 1.1),
                                 paint(mix(Tex.Palette.carrara, Tex.Palette.ground, 0.40),
                                       roughness: 0.85)))
    }

    // MARK: - flanking palazzi
    //
    // Their cornices and base courses are a second and third family of perspectival lines
    // converging on the same vanishing point as the pavement, and that redundancy is what makes the
    // perspective legible rather than merely correct. Heights vary block to block so the cornice
    // line steps rather than running dead level — a stepped cornice still converges, and proves it
    // was not drawn parallel to the panel edge by accident.

    /// (length along the facade, height to the cornice). Both rows begin at y = -10 rather than at
    /// the piazza proper: turned broadside, the panel looks straight down the x axis, and a row
    /// starting level with the Baptistery leaves an open corner between the Duomo's front and the
    /// first block — a hole in the enclosure exactly where the eye is closest to the wall.
    /// Both rows run y ∈ [-10, 104], meeting the closing row at its own facade plane.
    private static let westBlocks: [(Double, Double)] = [
        (20, 20.0), (18, 18.5), (22, 22.5), (19, 16.8), (18, 20.2), (17, 23.4),
    ]
    private static let eastBlocks: [(Double, Double)] = [
        (20, 18.8), (20, 21.5), (16, 17.4), (23, 19.6), (18, 23.0), (17, 16.6),
    ]
    /// The closing row behind the Baptistery, so the piazza is a room and not a void.
    private static let northBlocks: [(Double, Double)] = [
        (26, 19.5), (30, 23.5), (28, 20.5), (26, 22.0),
    ]

    private static func buildPalazzi(into parent: SCNNode) {
        // Facade planes at x = ∓37, outward normals pointing back into the piazza.
        for (x, blocks) in [(-37.0, westBlocks), (37.0, eastBlocks)] {
            let azimuth = x < 0 ? Double.pi / 2 : -Double.pi / 2
            var y = -10.0
            for (length, height) in blocks {
                buildPalazzo(into: parent, facadeCentre: SIMD3(x, y + length / 2, 0),
                             azimuth: azimuth, width: length, height: height)
                y += length
            }
        }
        var x = -52.0
        for (width, height) in northBlocks {
            buildPalazzo(into: parent, facadeCentre: SIMD3(x + width / 2, 104, 0),
                         azimuth: 0, width: width, height: height)
            x += width
        }
    }

    /// One block. `facadeCentre` is the midpoint of the facade plane at pavement level and
    /// `azimuth` the compass angle of its outward normal, so the mass, the cornice and the roof all
    /// follow from the one plane the eye actually sees.
    private static func buildPalazzo(into parent: SCNNode, facadeCentre c: SIMD3<Double>,
                                     azimuth: Double, width: Double, height: Double) {
        let depth = 16.0
        let out = outwardNormal(azimuth)   // from the facade plane into the piazza
        let spin = simd_quatf(angle: Float(azimuth), axis: SIMD3(0, 0, 1))

        // An SCNBox's local +Y is the facade's inward direction once spun, so the mass sits wholly
        // behind the plane and only the textured quad is at `c`.
        let mass = SCNBox(width: width, height: depth, length: height, chamferRadius: 0)
        mass.firstMaterial = paint(mix(Tex.Palette.stucco, Tex.Palette.ground, 0.25), roughness: 0.9)
        let massNode = SCNNode(geometry: mass)
        massNode.simdPosition = float3(c - out * (depth / 2) + SIMD3(0, 0, height / 2))
        massNode.simdOrientation = spin
        parent.addChildNode(massNode)

        let floors = max(3, Int((height / 4.6).rounded()))
        let bays = max(3, Int((width / 3.4).rounded()))
        let px = 640.0
        let image = Tex.palazzo(floors: floors, bays: bays,
                                size: CGSize(width: px, height: (px * height / width).rounded()))
        parent.addChildNode(facade(stone(image, roughness: 0.85), width, height,
                                   at: c + out * 0.03 + SIMD3(0, 0, height / 2),
                                   azimuth: azimuth))

        // Cornice and base course, projecting into the piazza so the sun cuts a hard line under
        // them. After the pavement these are the strongest horizontals in the scene.
        let trim = paint(mix(Tex.Palette.carrara, Tex.Palette.stucco, 0.30), roughness: 0.6)
        parent.addChildNode(slab(at: c + out * 0.55 + SIMD3(0, 0, height - 0.45),
                                 size: SIMD3(width + 0.8, 1.8, 0.9), trim, spin: spin))
        parent.addChildNode(slab(at: c + out * 0.25 + SIMD3(0, 0, 0.45),
                                 size: SIMD3(width + 0.3, 1.2, 0.9),
                                 paint(mix(Tex.Palette.stucco, Tex.Palette.ground, 0.5),
                                       roughness: 0.9),
                                 spin: spin))
        // Tile roof. Seen from below it is an edge, not a surface, so a band above the cornice is
        // all of it that is ever visible — and the warm line it puts along every skyline is the
        // point.
        parent.addChildNode(slab(at: c - out * (depth / 2) + SIMD3(0, 0, height + 0.45),
                                 size: SIMD3(width + 1.2, depth + 1.2, 0.9),
                                 paint(Tex.Palette.roofTile, roughness: 0.85), spin: spin))
    }

    // MARK: - mid-ground furniture
    //
    // The 15-to-40 m band was empty pavement in the first version, and an empty middle distance is
    // exactly what makes a rendered ground plane read as a surface rather than as receding space.

    private static func buildFurniture(into parent: SCNNode) {
        // Granite column with a bronze figure, 23 m out and directly in front of the campanile's
        // near face — the occlusion is the reason for the position.
        let column = Furniture.column(height: 11)
        column.simdPosition = float3(SIMD3(9, 21, 0))
        parent.addChildNode(column)

        let well = Furniture.wellhead()
        well.simdPosition = float3(SIMD3(-6, 34, 0))
        // Skewed off the paving grid: real street furniture never lines up with it, and a wellhead
        // square to the orthogonals reads as part of the construction rather than as an object.
        well.simdOrientation = simd_quatf(angle: 0.36, axis: SIMD3(0, 0, 1))
        parent.addChildNode(well)

        // Kerb ring around the Baptistery. It crosses in front of the stylobate at r = 21, which
        // puts a hard elliptical edge between the eye and the steps: the cheapest depth cue there
        // is, and the pavement's own grid stops at y = 55 so the two never collide.
        let kerb = Furniture.kerbRing(radius: 21, count: 24)
        kerb.simdPosition = float3(SIMD3(0, baptisteryDistance, 0))
        parent.addChildNode(kerb)

        // A second, shorter column out to the west. Without it, turning left found nothing but
        // pavement and a distant facade — the same flat tableau the whole rebuild is against, just
        // pointed 40 degrees the other way.
        let westColumn = Furniture.column(height: 8.5)
        westColumn.simdPosition = float3(SIMD3(-17, 15, 0))
        parent.addChildNode(westColumn)

        // The Duomo's own flight, climbing away from the station to the facade at y = -9. Built
        // climbing toward +Y, so it is turned to face the way the viewer came out.
        let flight = Furniture.steps(width: 34, steps: 4, rise: 0.30, tread: 0.90)
        flight.simdPosition = float3(SIMD3(0, -5.4, 0))
        flight.simdOrientation = simd_quatf(angle: .pi, axis: SIMD3(0, 0, 1))
        parent.addChildNode(flight)
    }

    /// The sun as an object, not as paint on the sky.
    ///
    /// The background cube is sampled by the true view direction, so it does not reflect: painted
    /// there, the sun would sit in the wrong half of a mirror, which is fatal when the sun is the
    /// thing being watched. As geometry under the world node it reflects with everything else, and
    /// the drawn bloom then lands on it by construction rather than by agreement.
    private static func buildSun(into parent: SCNNode) {
        let d = 350.0
        let disc = SCNSphere(radius: 6.1)   // ~2 degrees across: a truthful half-degree only aliases
        disc.segmentCount = 24
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor(srgbRed: 1.0, green: 0.985, blue: 0.92, alpha: 1)
        m.emission.contents = NSColor(srgbRed: 1.0, green: 0.985, blue: 0.92, alpha: 1)
        m.writesToDepthBuffer = false
        disc.firstMaterial = m
        let node = SCNNode(geometry: disc)
        node.simdPosition = float3(sunDirection * d)
        node.castsShadow = false
        parent.addChildNode(node)
    }

    // MARK: - light

    /// From the piazza up at the sun: unit, piazza frame. Late morning, well round to the west and
    /// low enough that the campanile lays thirty-odd metres of shadow back across the pavement.
    /// Lower than it was — a high sun puts every shadow under its own building, which is exactly
    /// the flat, placeless light the scene had. The sky is painted from this same vector.
    static let sunDirection = simd_normalize(SIMD3<Double>(-0.78, 0.20, 0.59))


    private static func buildLighting(into parent: SCNNode) {
        let sun = SCNLight()
        sun.type = .directional
        sun.color = NSColor(srgbRed: 1.0, green: 0.965, blue: 0.885, alpha: 1)
        sun.intensity = 1500
        sun.castsShadow = true
        sun.shadowMapSize = CGSize(width: 2048, height: 2048)
        sun.shadowSampleCount = 16
        sun.shadowRadius = 2
        // Nearly opaque, and measured rather than guessed: with the ambient and the sky fill both
        // lighting the shadowed pavement, anything under ~0.85 leaves the cast shadows at a few
        // percent of contrast and the piazza reads as flat-lit.
        sun.shadowColor = NSColor(srgbRed: 0.17, green: 0.17, blue: 0.22, alpha: 0.88)
        // Without this the shadow projection is fitted automatically and the settings below are
        // ignored, which at piazza scale means a shadow map spread over kilometres.
        sun.automaticallyAdjustsShadowProjection = false
        sun.orthographicScale = 160
        sun.zNear = 1
        sun.zFar = 500
        let sunNode = SCNNode()
        sunNode.light = sun
        // Late morning: high, well to the left, and a little beyond the campanile, so the tower
        // throws 30-odd metres of shadow back across the pavement toward the viewer. The +Y
        // component is kept small on purpose — push it and the Baptistery's near face, the one
        // face the whole building was oriented to present, falls entirely into shade.
        // Parked far enough out along the sun's own direction that the whole square is inside the
        // shadow frustum. A directional light takes only its orientation from this, not its
        // distance, but the shadow projection is built around the node.
        let aim = SIMD3<Double>(4, 46, 0)
        sunNode.simdPosition = float3(aim + sunDirection * 190)
        sunNode.look(at: SCNVector3(Float(aim.x), Float(aim.y), Float(aim.z)),
                     up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
        parent.addChildNode(sunNode)

        let sky = SCNLight()
        sky.type = .ambient
        // Warm, not blue. The previous scene's ambient was sky-coloured, which left every surface
        // facing away from the sun a cold grey and made painted stone read as plastic; bounced
        // light in a paved Italian square comes off the pavement, and the pavement is ochre.
        sky.color = NSColor(srgbRed: 0.93, green: 0.87, blue: 0.75, alpha: 1)
        sky.intensity = 300
        let skyNode = SCNNode()
        skyNode.light = sky
        parent.addChildNode(skyNode)
    }

    // MARK: - construction helpers

    /// SCNPlane, SCNCylinder and SCNCone are all born about SceneKit's +Y. This puts their axis on
    /// the piazza's +Z and, for a plane, leaves it facing -Y.

    /// A vertical quad standing in the piazza frame, centred on `p`. `azimuth` is the compass angle
    /// of its outward normal: 0 faces -Y, back toward the viewing station.
    private static func facade(_ material: SCNMaterial, _ width: Double, _ height: Double,
                               at p: SIMD3<Double>, azimuth: Double) -> SCNNode {
        let plane = SCNPlane(width: width, height: height)
        plane.firstMaterial = material
        let node = SCNNode(geometry: plane)
        node.simdPosition = float3(p)
        node.simdOrientation = simd_quatf(angle: Float(azimuth), axis: SIMD3(0, 0, 1)) * standUp
        return node
    }

    /// The one definition of "which way is out": the horizontal unit normal at compass angle
    /// `azimuth`, where 0 points -Y, back toward the viewing station. Every wall in this file is
    /// placed by an azimuth and this function, so a facade and the cornice over it cannot disagree.
    private static func outwardNormal(_ azimuth: Double) -> SIMD3<Double> {
        SIMD3(sin(azimuth), -cos(azimuth), 0)
    }

    /// Face `k` of a regular `sides`-gon standing on the pavement. Face 0 always looks back at the
    /// viewing station, which is why the Baptistery presents a flat face square-on and the
    /// campanile a flat side.
    private static func polyFace(_ k: Int, sides: Int) -> (azimuth: Double,
                                                           outward: SIMD3<Double>) {
        let a = 2 * Double.pi * Double(k) / Double(max(1, sides))
        return (a, outwardNormal(a))
    }

    /// Corner `k` of the same polygon — halfway in azimuth between faces k-1 and k. `radius` is the
    /// circumradius, not the apothem.
    private static func polyCorner(_ k: Int, sides: Int, radius: Double, centre: SIMD3<Double>,
                                   z: Double) -> SIMD3<Float> {
        let step = 2 * Double.pi / Double(max(1, sides))
        let a = Double(k) * step - step / 2
        return float3(centre + SIMD3(sin(a) * radius, -cos(a) * radius, z - centre.z))
    }

    /// One horizontal band of a regular prism — a step, a cornice — built face by face so its
    /// corners line up with the revetment above it. `apothem` is the band's outer face distance and
    /// it grows inward by `depth`.
    private static func polyBand(centre: SIMD3<Double>, sides: Int, apothem: Double,
                                 z0: Double, z1: Double, depth: Double,
                                 _ material: SCNMaterial) -> SCNNode {
        let group = SCNNode()
        // Exactly the outer face's length, so consecutive boxes meet at the corner and no further.
        // The inner edges then overlap into the neighbour, which is invisible — it is buried in
        // the solid. Adding `depth` here instead, to close a mitre that was never open, overhangs
        // each corner by depth/2 and gives every cornice, step and lantern band eight visible tabs.
        let side = 2 * apothem * tan(.pi / Double(max(3, sides)))
        for k in 0..<max(3, sides) {
            let (azimuth, outward) = polyFace(k, sides: sides)
            let box = SCNBox(width: side, height: depth, length: z1 - z0, chamferRadius: 0)
            box.firstMaterial = material
            let node = SCNNode(geometry: box)
            node.simdPosition = float3(centre + outward * (apothem - depth / 2)
                                       + SIMD3(0, 0, (z0 + z1) / 2))
            node.simdOrientation = simd_quatf(angle: Float(azimuth), axis: SIMD3(0, 0, 1))
            group.addChildNode(node)
        }
        return group
    }

    /// A truncated pyramid between two horizontal rings of the same polygon: the Baptistery's roof,
    /// eaves to lantern floor. Two triangles a face, wound so the normals face out.
    private static func polyRoof(centre: SIMD3<Double>, sides: Int,
                                 lower: (radius: Double, z: Double),
                                 upper: (radius: Double, z: Double),
                                 _ material: SCNMaterial) -> SCNNode {
        var tris: [[SIMD3<Float>]] = []
        for k in 0..<max(3, sides) {
            let a0 = polyCorner(k, sides: sides, radius: lower.radius, centre: centre, z: lower.z)
            let a1 = polyCorner(k + 1, sides: sides, radius: lower.radius, centre: centre,
                                z: lower.z)
            let b0 = polyCorner(k, sides: sides, radius: upper.radius, centre: centre, z: upper.z)
            let b1 = polyCorner(k + 1, sides: sides, radius: upper.radius, centre: centre,
                                z: upper.z)
            tris.append([a0, b1, b0])
            tris.append([a0, a1, b1])
        }
        return SCNNode(geometry: flatMesh(tris, material))
    }

}
