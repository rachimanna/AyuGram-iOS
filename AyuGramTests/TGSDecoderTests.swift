import XCTest
@testable import AyuGram

final class TGSDecoderTests: XCTestCase {
    private let gzip = Data(base64Encoded: "H4sIAAAAAAAC/6tWKlOyUjLVM9UzV9JRykmsTC0qVrKKjq0FAMLIeiQZAAAA")!

    func testGzipDecodesJSON() throws {
        let decoded = try TGSDecoder.decompress(gzip)
        XCTAssertEqual(String(data: decoded, encoding: .utf8), "{\"v\":\"5.5.7\",\"layers\":[]}")
    }

    func testRejectsTruncatedAndCorruptStreams() {
        XCTAssertThrowsError(try TGSDecoder.decompress(Data(gzip.dropLast(5))))
        var corrupted = gzip
        corrupted[corrupted.count - 8] ^= 0xff
        XCTAssertThrowsError(try TGSDecoder.decompress(corrupted))
        XCTAssertThrowsError(try TGSDecoder.decompress(Data()))
    }

    func testRejectsExpansionOverLimit() {
        XCTAssertThrowsError(try TGSDecoder.decompress(gzip, limit: 10))
    }
}
