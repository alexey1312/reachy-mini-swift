import Foundation
import simd

/// Triangle soup straight out of an STL file.
///
/// Vertices are deliberately not welded: STL stores one normal per facet, and
/// keeping three separate vertices per triangle preserves the faceted look of a
/// 3D-printed part. Welding would average the normals and turn crisp edges soft.
public struct STLMesh: Sendable, Equatable {
    public let positions: [SIMD3<Float>]
    public let normals: [SIMD3<Float>]
    public let indices: [UInt32]

    public init(positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]) {
        self.positions = positions
        self.normals = normals
        self.indices = indices
    }

    public var triangleCount: Int {
        indices.count / 3
    }

    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard let first = positions.first else { return nil }
        return positions.dropFirst().reduce((first, first)) { box, point in
            (simd_min(box.0, point), simd_max(box.1, point))
        }
    }
}

public enum STLDecodeError: Error, Equatable, LocalizedError {
    case tooShort
    case truncated(expected: Int, actual: Int)
    case malformedASCII(line: Int)
    case empty

    public var errorDescription: String? {
        switch self {
        case .tooShort:
            "STL file is too short to contain a header"
        case let .truncated(expected, actual):
            "STL file is truncated: expected \(expected) bytes, found \(actual)"
        case let .malformedASCII(line):
            "Malformed ASCII STL at line \(line)"
        case .empty:
            "STL file contains no usable triangles"
        }
    }
}

/// Reads both STL flavours.
///
/// Model I/O could do this, but only from a file URL, and it is free to weld
/// vertices — which would cost the faceted shading these parts need. A decoder
/// over `Data` is also a pure function, so it can be tested without a filesystem
/// or a Metal device.
public enum STLDecoder {
    private static let headerSize = 80
    private static let triangleStride = 50

    public static func decode(_ data: Data) throws -> STLMesh {
        guard data.count >= headerSize + 4 else {
            throw STLDecodeError.tooShort
        }
        let mesh = try isBinary(data) ? decodeBinary(data) : decodeASCII(data)
        guard !mesh.indices.isEmpty else {
            throw STLDecodeError.empty
        }
        return mesh
    }

    /// Not decided by a leading "solid": plenty of exporters write that word into
    /// a binary file's 80-byte header. The declared triangle count matching the
    /// file length is the only reliable signal.
    private static func isBinary(_ data: Data) -> Bool {
        let count = data.withUnsafeBytes { raw in
            Int(raw.loadUnaligned(fromByteOffset: headerSize, as: UInt32.self).littleEndian)
        }
        return data.count == headerSize + 4 + count * triangleStride
    }

    private static func decodeBinary(_ data: Data) throws -> STLMesh {
        let count = data.withUnsafeBytes { raw in
            Int(raw.loadUnaligned(fromByteOffset: headerSize, as: UInt32.self).littleEndian)
        }
        let expected = headerSize + 4 + count * triangleStride
        guard data.count >= expected else {
            throw STLDecodeError.truncated(expected: expected, actual: data.count)
        }

        var builder = Builder(capacity: count)
        data.withUnsafeBytes { raw in
            for triangle in 0 ..< count {
                let base = headerSize + 4 + triangle * triangleStride
                // Offsets are not four-byte aligned once the 84-byte prologue is
                // passed, so an aligned load would trap on arm64.
                func float(_ index: Int) -> Float {
                    Float(bitPattern: raw.loadUnaligned(
                        fromByteOffset: base + index * 4,
                        as: UInt32.self
                    ).littleEndian)
                }
                builder.add(
                    normal: SIMD3(float(0), float(1), float(2)),
                    SIMD3(float(3), float(4), float(5)),
                    SIMD3(float(6), float(7), float(8)),
                    SIMD3(float(9), float(10), float(11))
                )
            }
        }
        return builder.finish()
    }

    private static func decodeASCII(_ data: Data) throws -> STLMesh {
        guard let text = String(data: data, encoding: .utf8) else {
            throw STLDecodeError.malformedASCII(line: 0)
        }
        var builder = Builder(capacity: 0)
        var normal = SIMD3<Float>.zero
        var corners: [SIMD3<Float>] = []

        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let fields = rawLine.split(whereSeparator: \.isWhitespace)
            guard let keyword = fields.first else { continue }
            switch keyword {
            case "facet":
                normal = Self.vector(fields.dropFirst(2)) ?? .zero
                corners.removeAll(keepingCapacity: true)
            case "vertex":
                guard let point = Self.vector(fields.dropFirst()) else {
                    throw STLDecodeError.malformedASCII(line: offset + 1)
                }
                corners.append(point)
            case "endfacet":
                guard corners.count == 3 else {
                    throw STLDecodeError.malformedASCII(line: offset + 1)
                }
                builder.add(normal: normal, corners[0], corners[1], corners[2])
            default:
                continue
            }
        }
        return builder.finish()
    }

    private static func vector(_ fields: some Collection<Substring>) -> SIMD3<Float>? {
        let values = fields.compactMap { Float($0) }
        guard values.count >= 3 else { return nil }
        return SIMD3(values[0], values[1], values[2])
    }

    /// Accumulates triangles, repairing normals and dropping degenerate facets.
    private struct Builder {
        private var positions: [SIMD3<Float>] = []
        private var normals: [SIMD3<Float>] = []
        private var indices: [UInt32] = []

        init(capacity: Int) {
            positions.reserveCapacity(capacity * 3)
            normals.reserveCapacity(capacity * 3)
            indices.reserveCapacity(capacity * 3)
        }

        mutating func add(
            normal: SIMD3<Float>,
            _ first: SIMD3<Float>,
            _ second: SIMD3<Float>,
            _ third: SIMD3<Float>
        ) {
            // A zero normal is legal in the format and means "work it out";
            // an unnormalised one makes RealityKit's lighting misbehave.
            let geometric = simd_cross(second - first, third - first)
            let resolved = simd_length(normal) > 1e-12 ? normal : geometric
            guard simd_length(resolved) > 1e-12 else {
                return // Degenerate facet: zero area, nothing to shade.
            }
            let unit = simd_normalize(resolved)
            let base = UInt32(positions.count)
            positions.append(contentsOf: [first, second, third])
            normals.append(contentsOf: [unit, unit, unit])
            indices.append(contentsOf: [base, base + 1, base + 2])
        }

        func finish() -> STLMesh {
            STLMesh(positions: positions, normals: normals, indices: indices)
        }
    }
}
