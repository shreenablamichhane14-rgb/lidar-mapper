import Foundation

/// Little-endian binary builder. Every binary writer (STL, PLY, GLB, ZIP) goes through
/// this type so byte layouts are explicit and never depend on host byte order.
struct ByteWriter {
    /// Bytes written so far.
    private(set) var data: Data

    /// Creates an empty writer, optionally reserving `capacity` bytes up front.
    init(capacity: Int = 0) {
        data = Data()
        if capacity > 0 { data.reserveCapacity(capacity) }
    }

    /// Number of bytes written so far (the offset of the next byte).
    var count: Int { data.count }

    /// Appends one byte.
    mutating func appendUInt8(_ value: UInt8) {
        data.append(value)
    }

    /// Appends a 16-bit unsigned integer, little endian.
    mutating func appendUInt16(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// Appends a 32-bit unsigned integer, little endian.
    mutating func appendUInt32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// Appends an IEEE 754 single precision float, little endian.
    mutating func appendFloat32(_ value: Float32) {
        appendUInt32(value.bitPattern)
    }

    /// Appends raw bytes unchanged.
    mutating func appendData(_ bytes: Data) {
        data.append(bytes)
    }

    /// Appends the UTF-8 bytes of `string` with no terminator.
    mutating func appendString(_ string: String) {
        data.append(contentsOf: Array(string.utf8))
    }

    /// Appends `string` as exactly `length` bytes: truncated if longer, padded with
    /// `padding` if shorter (fixed-size header fields such as the STL header).
    mutating func appendFixedString(_ string: String, length: Int, padding: UInt8 = 0) {
        var bytes = Array(string.utf8.prefix(length))
        if bytes.count < length {
            bytes.append(contentsOf: [UInt8](repeating: padding, count: length - bytes.count))
        }
        data.append(contentsOf: bytes)
    }

    /// Appends `count` copies of `byte` (nothing when `count` is zero or negative).
    mutating func appendPadding(_ count: Int, byte: UInt8 = 0) {
        guard count > 0 else { return }
        data.append(contentsOf: [UInt8](repeating: byte, count: count))
    }

    /// Pads with `byte` until `count` is a multiple of `alignment`.
    mutating func align(to alignment: Int, byte: UInt8 = 0) {
        appendPadding(ByteWriter.padding(for: count, alignment: alignment), byte: byte)
    }

    /// Bytes needed to bring `length` up to the next multiple of `alignment`.
    static func padding(for length: Int, alignment: Int) -> Int {
        guard alignment > 1 else { return 0 }
        let remainder = length % alignment
        return remainder == 0 ? 0 : alignment - remainder
    }
}
