import Foundation

/// Wraps a request body in a real gzip stream (SONNY-146).
///
/// **Why this exists rather than a one-line call.** `NSData.compressed(using: .zlib)` produces **raw
/// DEFLATE** — no gzip container and no zlib container, despite the algorithm's name. Handing that
/// to a server under `Content-Encoding: gzip` fails to inflate: verified directly against an
/// independent implementation, which rejected it with "Not a gzipped file (b'\xed\xc1')". So the
/// framing is added here, and it is the whole reason this type is not two lines at a call site.
///
/// `gzip` rather than `deflate` deliberately. RFC 7230 defines `deflate` as the *zlib* container,
/// while much of the deployed world sends raw DEFLATE under that name, so the label is ambiguous in
/// practice and its meaning would depend on whichever server is on the far end. `gzip` has one
/// meaning, and it is the encoding `docs/sonny-backend-api-contract.md` §6.4 already obliges Sonny's
/// own backend to accept.
public enum HTTPBodyCompression {
    /// The gzip member header: magic, DEFLATE method, no flags, no mtime, no extra flags, unknown OS.
    /// Fixed bytes rather than a computed value — nothing here varies per body.
    private static let header = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])

    /// `data` as a gzip stream: header, raw DEFLATE, CRC-32 of the *uncompressed* bytes, then its
    /// length modulo 2^32 — both little-endian, as the format requires.
    ///
    /// The length is deliberately truncated rather than guarded: gzip's ISIZE field is defined as the
    /// input size mod 2^32, so a body above 4 GiB is not an error here, it is the format working as
    /// specified. Nothing Sonny sends is remotely near that — the vision route's own ceiling is about
    /// 4 MB — and a guard would be a check for a condition this caller cannot reach.
    public static func gzipped(_ data: Data) throws -> Data {
        var out = header
        out.append(try (data as NSData).compressed(using: .zlib) as Data)
        var checksum = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &checksum) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    /// CRC-32 (IEEE 802.3, the polynomial gzip uses), computed with a lazily built table.
    ///
    /// Hand-rolled because Foundation exposes none and the alternative is linking zlib for sixteen
    /// lines. Pinned against the published vector for "The quick brown fox jumps over the lazy dog",
    /// `0x414FA339`, so a transcription error in the table or the polynomial fails a test rather than
    /// producing a stream that inflates to the right bytes and then fails its own integrity check at
    /// the far end — which is the quiet version of this bug.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()
}
