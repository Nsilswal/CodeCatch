import Foundation

/// Finds a one-time / MFA code inside a message body.
///
/// Strategy:
/// 1. The message must contain a verification keyword ("code", "OTP", "verify", ...).
///    This keeps random numbers (order IDs, prices, phone numbers) from being copied.
/// 2. Collect numeric candidates (4–8 digits, or "123 456" / "123-456").
/// 3. Pick the candidate closest to a keyword. Year-like numbers are penalised.
/// 4. If there is no numeric candidate, accept an uppercase alphanumeric code
///    right after the word "code" (e.g. "Your code: K7XQ92").
public enum CodeExtractor {

    private static let keywordRegex = try! NSRegularExpression(
        pattern: #"\b(codes?|verification|verify|otp|passcode|password|pin|2fa|mfa|two[- ]factor|one[- ]time|log ?in|sign[- ]?in|security|authenticat\w*|confirm\w*|token)\b|验证码|驗證碼|código|codice|kod|コード|인증"#,
        options: [.caseInsensitive]
    )

    /// Prefixed codes like "G-123456" (Google) or "FB-12345".
    private static let prefixedRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])[A-Z]{1,3}-(\d{4,8})(?![0-9A-Za-z])"#
    )

    /// Standalone numbers. Not part of a phone number, price, decimal, date, URL or word.
    private static let numericRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9$€£¥#+/.:,\-])(\d{3}[ \-]\d{3}|\d{4,8})(?![0-9A-Za-z%]|[.,:/\-]\d)"#
    )

    /// Alphanumeric codes directly after "code".
    private static let alnumRegex = try! NSRegularExpression(
        pattern: #"\bcode\b\W{0,12}(?:is\W{0,3})?\b((?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])[A-Z0-9]{4,10})\b"#,
        options: [.caseInsensitive]
    )

    public static func extract(from text: String) -> String? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        let keywords = keywordRegex.matches(in: text, range: full).map(\.range)
        guard !keywords.isEmpty else { return nil }

        if let m = prefixedRegex.firstMatch(in: text, range: full) {
            return ns.substring(with: m.range(at: 1))
        }

        var best: (code: String, score: Int)?
        for m in numericRegex.matches(in: text, range: full) {
            let r = m.range(at: 1)
            let raw = ns.substring(with: r)
            let digits = raw.filter(\.isNumber)
            var score = -distance(r, keywords)
            if digits.count == 4, let n = Int(digits), (1900...2099).contains(n) {
                score -= 200  // probably a year
            }
            if best == nil || score > best!.score {
                best = (digits, score)
            }
        }
        if let best { return best.code }

        if let m = alnumRegex.firstMatch(in: text, range: full) {
            let candidate = ns.substring(with: m.range(at: 1))
            // Uppercase in the original message, so we skip normal words.
            if candidate == candidate.uppercased() { return candidate }
        }
        return nil
    }

    private static func distance(_ r: NSRange, _ keywords: [NSRange]) -> Int {
        keywords.map { k in
            if NSIntersectionRange(r, k).length > 0 { return 0 }
            return r.location >= NSMaxRange(k)
                ? r.location - NSMaxRange(k)
                : k.location - NSMaxRange(r)
        }.min() ?? Int.max / 2
    }
}
