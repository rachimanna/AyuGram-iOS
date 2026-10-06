import Foundation
import zlib

/// Telegram TGS contains gzip-compressed Lottie JSON.
enum TGSDecoder {
    enum DecodeError: Error { case invalidData, tooLarge }

    static func decompress(_ data: Data, limit: Int = 8 * 1024 * 1024) throws -> Data {
        guard !data.isEmpty, data.count <= 1024 * 1024, limit > 0 else {
            throw DecodeError.invalidData
        }
        var stream = z_stream()
        guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw DecodeError.invalidData
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(data.count)
            var result = Data()
            var chunk = [UInt8](repeating: 0, count: 32 * 1024)
            while true {
                let status = chunk.withUnsafeMutableBytes { output -> Int32 in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress!
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let count = chunk.count - Int(stream.avail_out)
                guard result.count + count <= limit else { throw DecodeError.tooLarge }
                result.append(contentsOf: chunk.prefix(count))
                if status == Z_STREAM_END { return result }
                guard status == Z_OK, count > 0 else { throw DecodeError.invalidData }
            }
        }
    }
}
