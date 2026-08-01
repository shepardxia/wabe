// The handful of things every piece of the scene needs: a material, a colour blend, a mesh, and
// the rotation that stands a SceneKit primitive up in a Z-up world.
//
import AppKit
import SceneKit
import simd

/// SCNCylinder, SCNCone, SCNTube and SCNPlane are all born about SceneKit's +Y. The piazza is Z-up,
/// so every one of them carries this. A building lying on its side is the classic failure here.
let standUp = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))

func float3(_ v: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }

func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    a.blended(withFraction: t, of: b) ?? a
}

func paint(_ color: NSColor, roughness: CGFloat, metalness: CGFloat = 0) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .physicallyBased
    m.diffuse.contents = color
    m.roughness.contents = roughness
    m.metalness.contents = metalness
    return m
}

/// An axis-aligned block: `size` is its full extent in x, y and z, `spin` an optional rotation
/// about the vertical. Cornices, plinths, string courses, kerbs and roofs are all this.
func slab(at p: SIMD3<Double>, size: SIMD3<Double>, _ material: SCNMaterial,
          spin: simd_quatf? = nil) -> SCNNode {
    let box = SCNBox(width: size.x, height: size.y, length: size.z, chamferRadius: 0)
    box.firstMaterial = material
    let node = SCNNode(geometry: box)
    node.simdPosition = float3(p)
    if let spin { node.simdOrientation = spin }
    return node
}

func stone(_ image: NSImage, roughness: CGFloat) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .physicallyBased
    m.diffuse.contents = image
    m.diffuse.mipFilter = .linear
    m.roughness.contents = roughness
    m.metalness.contents = 0
    return m
}

func flatMesh(_ faces: [[SIMD3<Float>]], _ material: SCNMaterial) -> SCNGeometry {
    var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], indices: [Int32] = []
    for face in faces where face.count >= 3 {
        let n = simd_normalize(simd_cross(face[1] - face[0], face[2] - face[0]))
        let base = Int32(vertices.count)
        for v in face {
            vertices.append(SCNVector3(CGFloat(v.x), CGFloat(v.y), CGFloat(v.z)))
            normals.append(SCNVector3(CGFloat(n.x), CGFloat(n.y), CGFloat(n.z)))
        }
        for t in 1..<(face.count - 1) {
            indices.append(contentsOf: [base, base + Int32(t), base + Int32(t + 1)])
        }
    }
    let geometry = SCNGeometry(
        sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
        elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    geometry.firstMaterial = material
    return geometry
}

func flatMesh(_ faces: [[SIMD3<Double>]], _ material: SCNMaterial) -> SCNGeometry {
    flatMesh(faces.map { $0.map(float3) }, material)
}
