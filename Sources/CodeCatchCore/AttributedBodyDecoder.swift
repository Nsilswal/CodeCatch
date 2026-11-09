import Foundation

/// On macOS 13+ the `message.text` column is often NULL. The text lives in
/// `message.attributedBody`, an NSAttributedString in Apple's legacy
/// "typedstream" format. Full decoding is complex, but the plain string
/// always follows the `NSString` class marker:
///
///     ... "NSString" 01 94 84 01 '+' <length> <utf8 bytes> ...
///
/// The length is one byte if < 0x80. 0x81 means a 2-byte little-endian length
/// follows. 0x82 means a 4-byte little-endian length follows.
public enum AttributedBodyDecoder {
    private static let marker = Array("NSString".utf8)

    public static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let start = find(marker, in: bytes) else { return nil }

        var i = start + marker.count
        let limit = min(bytes.count, i + 16)
        while i < limit, bytes[i] != 0x2B { i += 1 }  // '+'
        guard i < limit else { return nil }
        i += 1
        guard i < bytes.count else { return nil }

        let length: Int
        switch bytes[i] {
        case 0x81:
            guard i + 2 < bytes.count else { return nil }
            length = Int(bytes[i + 1]) | Int(bytes[i + 2]) << 8
            i += 3
        case 0x82:
            guard i + 4 < bytes.count else { return nil }
            length = Int(bytes[i + 1]) | Int(bytes[i + 2]) << 8
                | Int(bytes[i + 3]) << 16 | Int(bytes[i + 4]) << 24
            i += 5
        default:
            length = Int(bytes[i])
            i += 1
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i..<(i + length)], encoding: .utf8)
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] {
            if Array(hay[i..<(i + needle.count)]) == needle { return i }
        }
        return nil
    }
}
