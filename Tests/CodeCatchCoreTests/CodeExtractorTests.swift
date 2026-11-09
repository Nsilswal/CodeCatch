import XCTest
@testable import CodeCatchCore

final class CodeExtractorTests: XCTestCase {
    private func x(_ s: String) -> String? { CodeExtractor.extract(from: s) }

    func testCommonFormats() {
        XCTAssertEqual(x("Your verification code is 482913."), "482913")
        XCTAssertEqual(x("G-735204 is your Google verification code."), "735204")
        XCTAssertEqual(x("Your Uber code: 4821. Never share this code."), "4821")
        XCTAssertEqual(x("123456 is your Instagram code. Don't share it."), "123456")
        XCTAssertEqual(x("Your Apple Account code is: 918273. Don't share it with anyone."), "918273")
        XCTAssertEqual(x("Chase: Your one-time code is 55102938. It expires in 10 minutes."), "55102938")
        XCTAssertEqual(x("Use 382 917 to sign in to Amazon."), "382917")
        XCTAssertEqual(x("Your login code is 991-204"), "991204")
        XCTAssertEqual(x("<#> Your Discord security code: 7731 abcDEF123"), "7731")
        XCTAssertEqual(x("您的验证码是 667788"), "667788")
    }

    func testAlphanumeric() {
        XCTAssertEqual(x("Your code is K7XQ92"), "K7XQ92")
    }

    func testIgnoresNonCodes() {
        XCTAssertNil(x("Hey, are we still on for 1230 tomorrow?"))
        XCTAssertNil(x("Your order #482913 has shipped."))
        XCTAssertNil(x("Call me at 555-123-4567"))
        XCTAssertNil(x("Dinner was $1250, insane"))
        XCTAssertNil(x("Your code is ready"))
    }

    func testAvoidsDistractors() {
        XCTAssertEqual(x("Bank of X: code 402917. Call 18005551234 if this wasn't you."), "402917")
        XCTAssertEqual(x("In 2025 we changed things. Your verification code is 8812."), "8812")
        XCTAssertEqual(x("Your code is 123456. Valid for 10 min. Amount $45.00"), "123456")
    }
}

final class AttributedBodyDecoderTests: XCTestCase {
    private func blob(_ s: String) -> Data {
        let body = Array(s.utf8)
        var d: [UInt8] = [0x04, 0x0B] + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84]
        d += Array("NSAttributedString".utf8) + [0x00, 0x84, 0x84]
        d += Array("NSObject".utf8) + [0x00, 0x85, 0x92, 0x84, 0x84, 0x84]
        d += Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
        if body.count < 0x80 {
            d.append(UInt8(body.count))
        } else {
            d += [0x81, UInt8(body.count & 0xFF), UInt8(body.count >> 8)]
        }
        d += body + [0x86, 0x84, 0x02, 0x69, 0x49]
        return Data(d)
    }

    func testShort() {
        XCTAssertEqual(AttributedBodyDecoder.decode(blob("Your code is 123456")), "Your code is 123456")
    }

    func testLong() {
        let s = String(repeating: "a", count: 300) + " 验证码 998877"
        XCTAssertEqual(AttributedBodyDecoder.decode(blob(s)), s)
    }

    func testGarbage() {
        XCTAssertNil(AttributedBodyDecoder.decode(Data([1, 2, 3])))
    }
}
