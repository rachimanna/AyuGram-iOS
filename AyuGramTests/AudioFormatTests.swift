import XCTest
@testable import AyuGram

final class AudioFormatTests: XCTestCase {
    func testDetectsExtensionlessOggWithoutTreatingM4AAsOpus() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ogg = directory.appendingPathComponent("voice")
        let m4a = directory.appendingPathComponent("other_voice")
        try Data("OggS\u{0}\u{0}".utf8).write(to: ogg)
        try Data([0, 0, 0, 24] + Array("ftypM4A ".utf8)).write(to: m4a)
        XCTAssertTrue(AudioPlayback.isOggFile(ogg.path))
        XCTAssertFalse(AudioPlayback.isOggFile(m4a.path))
        XCTAssertFalse(AudioPlayback.isOggFile(directory.appendingPathComponent("missing").path))
    }
}
