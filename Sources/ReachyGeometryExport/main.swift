import Foundation
import ModelIO
import ReachyKit
import ReachySimulator
import simd

// The robot as one USD scene, for training an object tracker against.
//
// Not a product and not shipped: this writes the training *input* for Create ML's
// object-tracking template, whose output is the `.referenceobject` blob
// `ReachyScene` carries. It is an executable rather than a `Scripts/*.swift` for
// one reason — a script cannot link a target, so `URDFParser` and `STLDecoder`
// would have to be copied, and a robot exported by a second decoder is a robot
// that can drift from the one on screen. Everything here is the app's own reader.
//
// **It writes `.usdc`, not `.usdz`, and that is Model I/O's limit rather than a
// choice**: `MDLAsset.canExportFileExtension("usdz")` answers false on Xcode 27
// beta 6 (usdc, usda and obj answer true). The `geometry:usdz` mise task pipes the
// result through `/usr/bin/usdzip --arkitAsset`, which is Apple's own packager —
// it flattens composition arcs and adjusts the data to RealityKit's requirements,
// which is exactly the shape a reference object is trained from. Hand-rolling the
// archive would be a second answer to "what is a usdz".

enum ExportFailure: Error, CustomStringConvertible {
    case usage(String)
    case unsupportedExtension(String)
    case noVisuals
    case export(String)

    var description: String {
        switch self {
        case let .usage(message): "usage: \(message)"
        case let .unsupportedExtension(ext):
            """
            Model I/O cannot export '.\(ext)' — it answers canExportFileExtension \
            only for usdc, usda and obj. Write .usdc and package it with usdzip.
            """
        case .noVisuals: "the description names no mesh visuals"
        case let .export(message): "export failed: \(message)"
        }
    }
}

/// Carries URDF's Z-up into the Y-up frame RealityKit draws in.
///
/// The same rotation `RobotSceneGraph` puts on its root, and it has to be baked
/// here rather than left to the reader: a reference object is trained from this
/// file's frame, so an unrotated export produces an anchor that stands the robot
/// on its side, with nothing on screen to say which of the two was wrong.
/// `URDFFlatteningTests` holds the pair.
let zUpToYUp = simd_double4x4(simd_quatd(angle: -.pi / 2, axis: SIMD3(1, 0, 0)))

struct Options {
    let output: URL
    /// Off by default, and the reason is measured rather than aesthetic. The two
    /// antennas are **actuated** — `left_antenna` and `right_antenna` are two of the
    /// robot's nine actuators — and at the URDF's zero configuration they stand
    /// straight up, which is 14 cm of the export's 39 cm total: the body and head
    /// alone reach 0.249 m. A tracker fitted to a model whose tallest, thinnest,
    /// highest-contrast feature is somewhere else on the real robot is being taught
    /// the one thing that will not be there. Leaving them out is the lesser error —
    /// an appearance model that does not know about a part it then sees is ordinary
    /// clutter, while one that expects a part where it is not is a bad fit. Neither
    /// half of that can be settled without a device, which is why this is a flag
    /// and not a decision baked into the file.
    let includesAntennas: Bool
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var path: String?
    var includesAntennas = false
    var index = arguments.startIndex
    while index < arguments.endIndex {
        switch arguments[index] {
        case "--output", "-o":
            index += 1
            guard index < arguments.endIndex else {
                throw ExportFailure.usage("--output needs a path")
            }
            path = arguments[index]
        case "--with-antennas":
            includesAntennas = true
        case let other:
            throw ExportFailure.usage("unrecognised argument '\(other)'")
        }
        index += 1
    }
    guard let path else {
        throw ExportFailure.usage("ReachyGeometryExport --output <file.usdc> [--with-antennas]")
    }
    let url = URL(fileURLWithPath: path)
    let ext = url.pathExtension.lowercased()
    guard MDLAsset.canExportFileExtension(ext) else {
        throw ExportFailure.unsupportedExtension(ext)
    }
    return Options(output: url, includesAntennas: includesAntennas)
}

/// The URDF's own names for the two antenna joints. The daemon's actuator list
/// spells the body's differently (`body_rotation` against the URDF's `yaw_body`),
/// so these are read from the description rather than from the API — and
/// `linksBelow(jointNamed:)` answering the empty set for a name that is not there
/// is what keeps a description without antennas working.
let antennaJoints = ["left_antenna", "right_antenna"]

/// One `STLMesh` as a Model I/O mesh, sharing the buffers of every other visual
/// that names the same file.
///
/// Positions and normals are interleaved into one buffer because that is the
/// layout `MDLVertexDescriptor` describes most cheaply, and the triangle soup is
/// written through unchanged — `STLDecoder` refuses to weld vertices so the
/// faceted look of a printed part survives, and welding it here would undo that
/// where it matters most, in the appearance a tracker is fitted against.
struct MeshBuffers {
    let vertices: MDLMeshBuffer
    let indices: MDLMeshBuffer
    let vertexCount: Int
    let indexCount: Int
    /// Kept so the assembled size can be reported without reading the file back.
    /// A tracker is trained against an object of a stated size, and "0.23 m tall,
    /// standing on the ground plane" is the one property of this export a person
    /// can check against the robot on the desk in front of them.
    let corners: [SIMD3<Double>]

    init(_ mesh: STLMesh, allocator: MDLMeshBufferAllocator) {
        var interleaved: [Float] = []
        interleaved.reserveCapacity(mesh.positions.count * 6)
        for (position, normal) in zip(mesh.positions, mesh.normals) {
            interleaved.append(contentsOf: [position.x, position.y, position.z])
            interleaved.append(contentsOf: [normal.x, normal.y, normal.z])
        }
        vertices = allocator.newBuffer(
            with: interleaved.withUnsafeBufferPointer { Data(buffer: $0) },
            type: .vertex
        )
        indices = allocator.newBuffer(
            with: mesh.indices.withUnsafeBufferPointer { Data(buffer: $0) },
            type: .index
        )
        vertexCount = mesh.positions.count
        indexCount = mesh.indices.count
        if let box = mesh.bounds {
            let low = SIMD3<Double>(box.min)
            let high = SIMD3<Double>(box.max)
            corners = (0 ..< 8).map { index in
                SIMD3(
                    index & 1 == 0 ? low.x : high.x,
                    index & 2 == 0 ? low.y : high.y,
                    index & 4 == 0 ? low.z : high.z
                )
            }
        } else {
            corners = []
        }
    }
}

/// The assembled model's extent, accumulated as it is built.
struct Bounds {
    private var low = SIMD3<Double>(repeating: .infinity)
    private var high = SIMD3<Double>(repeating: -.infinity)

    mutating func add(_ corners: [SIMD3<Double>], transform: simd_double4x4) {
        for corner in corners {
            let placed = transform * SIMD4(corner, 1)
            let point = SIMD3(placed.x, placed.y, placed.z)
            low = simd_min(low, point)
            high = simd_max(high, point)
        }
    }

    var description: String {
        guard low.x <= high.x else { return "empty" }
        let size = high - low
        return String(
            format: "%.3f × %.3f × %.3f m, base at y = %.4f",
            size.x, size.y, size.z, low.y
        )
    }
}

func vertexDescriptor() -> MDLVertexDescriptor {
    let descriptor = MDLVertexDescriptor()
    descriptor.attributes[0] = MDLVertexAttribute(
        name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0
    )
    descriptor.attributes[1] = MDLVertexAttribute(
        name: MDLVertexAttributeNormal, format: .float3, offset: MemoryLayout<Float>.stride * 3, bufferIndex: 0
    )
    descriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<Float>.stride * 6)
    return descriptor
}

/// The URDF's own colour, as the one material property a tracker's appearance
/// model can use. Flat CAD greys are the hard case for an appearance-based
/// tracker, so dropping them for a default grey would give away the only surface
/// variation this description carries.
func material(for color: URDFColor) -> MDLMaterial {
    let material = MDLMaterial(name: "urdf", scatteringFunction: MDLScatteringFunction())
    material.setProperty(MDLMaterialProperty(
        name: "baseColor",
        semantic: .baseColor,
        float3: SIMD3(Float(color.red), Float(color.green), Float(color.blue))
    ))
    material.setProperty(MDLMaterialProperty(name: "opacity", semantic: .opacity, float: Float(color.alpha)))
    material.setProperty(MDLMaterialProperty(name: "roughness", semantic: .roughness, float: 0.45))
    material.setProperty(MDLMaterialProperty(name: "metallic", semantic: .metallic, float: 0))
    return material
}

func run() throws {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    let output = options.output
    let bundle = BundledRobotGeometry()
    let urdf = try URDFParser.parse(bundle.urdf())
    let excluded = options.includesAntennas
        ? []
        : antennaJoints.reduce(into: Set<String>()) { $0.formUnion(urdf.linksBelow(jointNamed: $1)) }
    let placements = urdf.flattenedVisuals(excluding: excluded)
    guard !placements.isEmpty else { throw ExportFailure.noVisuals }

    let allocator = MDLMeshBufferDataAllocator()
    let descriptor = vertexDescriptor()
    var buffers: [String: MeshBuffers] = [:]
    var bounds = Bounds()
    let asset = MDLAsset(bufferAllocator: allocator)

    for placement in placements {
        let shared: MeshBuffers
        if let existing = buffers[placement.mesh] {
            shared = existing
        } else {
            let decoded = try STLDecoder.decode(bundle.stlAsset(named: placement.mesh))
            shared = MeshBuffers(decoded, allocator: allocator)
            buffers[placement.mesh] = shared
        }
        let submesh = MDLSubmesh(
            indexBuffer: shared.indices,
            indexCount: shared.indexCount,
            indexType: .uInt32,
            geometryType: .triangles,
            material: material(for: placement.color)
        )
        let mesh = MDLMesh(
            vertexBuffer: shared.vertices,
            vertexCount: shared.vertexCount,
            descriptor: descriptor,
            submeshes: [submesh]
        )
        mesh.name = "\(placement.link)_\(placement.mesh.replacingOccurrences(of: ".stl", with: ""))"
        let scale = simd_double4x4(diagonal: SIMD4(placement.scale, 1))
        let transform = zUpToYUp * placement.transform * scale
        mesh.transform = MDLTransform(matrix: simd_float4x4(transform))
        bounds.add(shared.corners, transform: transform)
        asset.add(mesh)
    }

    try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    do {
        try asset.export(to: output)
    } catch {
        throw ExportFailure.export(error.localizedDescription)
    }

    let meshes = Set(placements.map(\.mesh)).count
    print("""
    Wrote \(output.path)
      \(placements.count) visuals over \(meshes) meshes, \(urdf.links.count) links
      antennas \(options.includesAntennas ? "included" : "left out (\(excluded.count) links)")
      URDF zero configuration, Y-up, \(bounds.description)
    """)
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

private extension simd_float4x4 {
    init(_ matrix: simd_double4x4) {
        self.init(
            SIMD4<Float>(matrix.columns.0),
            SIMD4<Float>(matrix.columns.1),
            SIMD4<Float>(matrix.columns.2),
            SIMD4<Float>(matrix.columns.3)
        )
    }
}
