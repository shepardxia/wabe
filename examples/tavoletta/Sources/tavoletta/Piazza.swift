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

    static let orthogonals: [(SIMD3<Double>, SIMD3<Double>)] = (-8...8).map { k in
        let x = Double(k) * 4.4
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

    private static let campanileCentre = SIMD3<Double>(17, 26, 0)
    private static let campanileSide = 14.5

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
            parent.addChildNode(slab(at: c + SIMD3(0, 0, r.z1 + r.cornice / 2),
                                     size: SIMD3(campanileSide + 1.6, campanileSide + 1.6,
                                                 r.cornice),
                                     trim))
        }

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

    private static func buildDuomo(into parent: SCNNode) {
        let marble = paint(mix(Tex.Palette.carrara, Tex.Palette.ground, 0.22), roughness: 0.78)

        let frontY = -38.0, frontWidth = 60.0, frontHeight = 48.0
        parent.addChildNode(slab(at: SIMD3(0, frontY - 2.5, frontHeight / 2),
                                 size: SIMD3(frontWidth, 5, frontHeight), marble))
        // Twice the pixels of any other wall: this is the only surface the eye ever gets within
        // 9 m of, and at that range a 1024-wide texture puts about 140 px across a bronze door.
        parent.addChildNode(facade(stone(Tex.duomoFacade(size: CGSize(width: 2048, height: 1638)),
                                         roughness: 0.55),
                                   frontWidth, frontHeight,
                                   at: SIMD3(0, frontY + 0.04, frontHeight / 2), azimuth: .pi))

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

    private static let westBlocks: [(Double, Double)] = [
        (20, 20.0), (18, 18.5), (22, 22.5), (19, 16.8), (18, 20.2), (17, 23.4),
    ]
    private static let eastBlocks: [(Double, Double)] = [
        (20, 18.8), (20, 21.5), (16, 17.4), (23, 19.6), (18, 23.0), (17, 16.6),
    ]
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
        parent.addChildNode(slab(at: c - out * (depth / 2) + SIMD3(0, 0, height + 0.45),
                                 size: SIMD3(width + 1.2, depth + 1.2, 0.9),
                                 paint(Tex.Palette.roofTile, roughness: 0.85), spin: spin))
    }

    // MARK: - mid-ground furniture

    private static func buildFurniture(into parent: SCNNode) {
        // Granite column with a bronze figure, 23 m out and directly in front of the campanile's
        // near face — the occlusion is the reason for the position.
        let column = Furniture.column(height: 11)
        column.simdPosition = float3(SIMD3(9, 21, 0))
        parent.addChildNode(column)

        let well = Furniture.wellhead()
        well.simdPosition = float3(SIMD3(-6, 34, 0))
        well.simdOrientation = simd_quatf(angle: 0.36, axis: SIMD3(0, 0, 1))
        parent.addChildNode(well)

        let kerb = Furniture.kerbRing(radius: 21, count: 24)
        kerb.simdPosition = float3(SIMD3(0, baptisteryDistance, 0))
        parent.addChildNode(kerb)

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
        sun.shadowColor = NSColor(srgbRed: 0.17, green: 0.17, blue: 0.22, alpha: 0.88)
        sun.automaticallyAdjustsShadowProjection = false
        sun.orthographicScale = 160
        sun.zNear = 1
        sun.zFar = 500
        let sunNode = SCNNode()
        sunNode.light = sun
        let aim = SIMD3<Double>(4, 46, 0)
        sunNode.simdPosition = float3(aim + sunDirection * 190)
        sunNode.look(at: SCNVector3(Float(aim.x), Float(aim.y), Float(aim.z)),
                     up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
        parent.addChildNode(sunNode)

        let sky = SCNLight()
        sky.type = .ambient
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

    private static func outwardNormal(_ azimuth: Double) -> SIMD3<Double> {
        SIMD3(sin(azimuth), -cos(azimuth), 0)
    }

    private static func polyFace(_ k: Int, sides: Int) -> (azimuth: Double,
                                                           outward: SIMD3<Double>) {
        let a = 2 * Double.pi * Double(k) / Double(max(1, sides))
        return (a, outwardNormal(a))
    }

    private static func polyCorner(_ k: Int, sides: Int, radius: Double, centre: SIMD3<Double>,
                                   z: Double) -> SIMD3<Float> {
        let step = 2 * Double.pi / Double(max(1, sides))
        let a = Double(k) * step - step / 2
        return float3(centre + SIMD3(sin(a) * radius, -cos(a) * radius, z - centre.z))
    }

    private static func polyBand(centre: SIMD3<Double>, sides: Int, apothem: Double,
                                 z0: Double, z1: Double, depth: Double,
                                 _ material: SCNMaterial) -> SCNNode {
        let group = SCNNode()
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
