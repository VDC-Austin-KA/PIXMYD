import Foundation

// A minimal PNG encoder.
//
// Needed because the colour atlas has to leave the app as an image file that
// every importer reads, and the obvious way to make one — `UIImage.pngData()`
// or `CGImageDestination` — is Darwin-only. Putting the encoder here keeps it
// in `portableSources`, so `swift test` checks the bytes on Linux rather than
// discovering a malformed chunk on a phone.
//
// ## Stored deflate, not compressed
//
// PNG's IDAT is a zlib stream, and zlib's deflate has a "stored" block type
// that copies bytes through uncompressed. The file is then a valid PNG that any
// decoder reads, and the encoder is a hundred lines instead of a Huffman coder.
//
// The cost is size, and it is smaller than it looks for this use: the atlas is
// one texel per triangle of essentially random scan colour, which is close to
// incompressible anyway. A real deflate would win maybe 10% here and would be
// the largest and least-tested thing in the export path.
//
// If a future caller needs a genuinely compressible image — a mask, a
// screenshot — this is the wrong encoder for it and that is the point at which
// to reach for one that compresses.

enum PngWriter {
    /// PNG colour type 2: 8-bit RGB, no alpha.
    static let colorTypeRgb: UInt8 = 2

    enum PngError: Error, CustomStringConvertible {
        case badDimensions(width: Int, height: Int)
        case wrongPixelCount(expected: Int, got: Int)

        var description: String {
            switch self {
            case let .badDimensions(width, height):
                return "A PNG must be at least 1x1; got \(width)x\(height)."
            case let .wrongPixelCount(expected, got):
                return "Expected \(expected) bytes of RGB pixel data, got \(got)."
            }
        }
    }

    /// Encode 8-bit RGB pixels, row-major from the top-left.
    static func encodeRgb(width: Int, height: Int, rgb: [UInt8]) throws -> [UInt8] {
        guard width > 0, height > 0 else {
            throw PngError.badDimensions(width: width, height: height)
        }
        guard rgb.count == width * height * 3 else {
            throw PngError.wrongPixelCount(expected: width * height * 3, got: rgb.count)
        }

        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

        var ihdr: [UInt8] = []
        appendU32(&ihdr, UInt32(width))
        appendU32(&ihdr, UInt32(height))
        ihdr.append(8)              // bit depth
        ihdr.append(colorTypeRgb)
        ihdr.append(0)              // compression: deflate
        ihdr.append(0)              // filter method
        ihdr.append(0)              // no interlace
        appendChunk(&out, type: "IHDR", data: ihdr)

        // Each scanline is prefixed with its filter type. 0 is "none", which is
        // the right choice when the data is not being compressed afterwards:
        // any other filter only exists to make the deflate stage's job easier.
        var raw: [UInt8] = []
        raw.reserveCapacity(height * (1 + width * 3))
        for row in 0..<height {
            raw.append(0)
            let start = row * width * 3
            raw.append(contentsOf: rgb[start ..< start + width * 3])
        }

        appendChunk(&out, type: "IDAT", data: zlibStored(raw))
        appendChunk(&out, type: "IEND", data: [])
        return out
    }

    // MARK: - zlib

    /// Wrap bytes in a zlib stream of stored deflate blocks.
    static func zlibStored(_ raw: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        // CMF/FLG: deflate, 32K window, no preset dictionary. 0x78 0x01 is the
        // pair whose check bits work out, and is what every encoder emits for
        // "no compression".
        out.append(0x78)
        out.append(0x01)

        // A stored block's length field is 16 bits, so anything larger is split.
        let blockSize = 65535
        var index = 0
        repeat {
            let end = min(index + blockSize, raw.count)
            let length = end - index
            let isFinal = end == raw.count
            out.append(isFinal ? 1 : 0)
            out.append(UInt8(length & 0xFF))
            out.append(UInt8((length >> 8) & 0xFF))
            // NLEN is the ones complement of LEN, and decoders check it.
            let nlen = ~UInt16(length)
            out.append(UInt8(nlen & 0xFF))
            out.append(UInt8((nlen >> 8) & 0xFF))
            if length > 0 {
                out.append(contentsOf: raw[index ..< end])
            }
            index = end
        } while index < raw.count

        appendU32(&out, adler32(raw))
        return out
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        // 5552 is the largest run that cannot overflow the accumulator, so the
        // modulo only has to happen once per chunk rather than once per byte.
        var index = 0
        while index < bytes.count {
            let end = min(index + 5552, bytes.count)
            for i in index..<end {
                a &+= UInt32(bytes[i])
                b &+= a
            }
            a %= 65521
            b %= 65521
            index = end
        }
        return (b << 16) | a
    }

    // MARK: - Chunks

    private static func appendChunk(_ out: inout [UInt8], type: String, data: [UInt8]) {
        appendU32(&out, UInt32(data.count))
        let typeBytes = Array(type.utf8)
        out.append(contentsOf: typeBytes)
        out.append(contentsOf: data)
        appendU32(&out, crc32(typeBytes + data))
    }

    private static func appendU32(_ out: inout [UInt8], _ value: UInt32) {
        out.append(UInt8((value >> 24) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8(value & 0xFF))
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var c = UInt32(index)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    /// The CRC-32 of zip and PNG. Note E57 uses CRC-32C — same structure,
    /// different polynomial — and they are not interchangeable.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }
}
