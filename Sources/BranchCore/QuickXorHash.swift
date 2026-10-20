import Foundation

/// Microsoft's QuickXorHash, the content hash OneDrive reports for every file.
/// Port of the reference implementation: a 160-bit XOR accumulator that shifts 11 bits per byte,
/// finalized by XOR-ing in the little-endian length.
public struct QuickXorHash {
    private static let widthInBits = 160
    private static let shift = 11
    private static let bitsInLastCell = 32

    private var cells: [UInt64] = [0, 0, 0]
    private var lengthSoFar: Int64 = 0
    private var shiftSoFar = 0

    public init() {}

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { raw in
            update(raw.bindMemory(to: UInt8.self))
        }
    }

    public mutating func update(_ bytes: UnsafeBufferPointer<UInt8>) {
        let count = bytes.count
        guard count > 0 else { return }
        var cellIndex = shiftSoFar / 64
        var cellOffset = shiftSoFar % 64
        let iterations = min(count, Self.widthInBits)

        for i in 0..<iterations {
            let isLastCell = cellIndex == cells.count - 1
            let bitsInCell = isLastCell ? Self.bitsInLastCell : 64
            // Bytes i, i+160, i+320, … all land on the same bit position.
            var xored: UInt8 = 0
            var j = i
            while j < count {
                xored ^= bytes[j]
                j += Self.widthInBits
            }
            if cellOffset <= bitsInCell - 8 {
                cells[cellIndex] ^= UInt64(xored) << UInt64(cellOffset)
            } else {
                let next = isLastCell ? 0 : cellIndex + 1
                let low = bitsInCell - cellOffset
                cells[cellIndex] ^= UInt64(xored) << UInt64(cellOffset)
                cells[next] ^= UInt64(xored) >> UInt64(low)
            }
            cellOffset += Self.shift
            while cellOffset >= bitsInCell {
                cellIndex = isLastCell ? 0 : cellIndex + 1
                cellOffset -= bitsInCell
            }
        }
        shiftSoFar = (shiftSoFar + Self.shift * (count % Self.widthInBits)) % Self.widthInBits
        lengthSoFar += Int64(count)
    }

    public func finalize() -> Data {
        var out = [UInt8](repeating: 0, count: Self.widthInBits / 8)
        for (i, cell) in cells.enumerated() {
            for b in 0..<8 where i * 8 + b < out.count {
                out[i * 8 + b] = UInt8(truncatingIfNeeded: cell >> UInt64(b * 8))
            }
        }
        var length = lengthSoFar.littleEndian
        withUnsafeBytes(of: &length) { lengthBytes in
            for (i, byte) in lengthBytes.enumerated() {
                out[out.count - lengthBytes.count + i] ^= byte
            }
        }
        return Data(out)
    }

    /// Base64 form, as returned by Graph in `file.hashes.quickXorHash`.
    public func base64() -> String {
        finalize().base64EncodedString()
    }

    public static func hash(_ data: Data) -> String {
        var h = QuickXorHash()
        h.update(data)
        return h.base64()
    }

    /// Streams a file so large files aren't loaded into memory.
    public static func hash(path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var h = QuickXorHash()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            h.update(chunk)
        }
        return h.base64()
    }
}
