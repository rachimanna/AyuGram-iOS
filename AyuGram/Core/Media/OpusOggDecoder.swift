/*
 * Telegram voice notes are Opus in an Ogg container, which AVFoundation cannot play.
 * Android Telegram ships its own opus decoder (TMessagesProj/jni/opus); the iOS port decodes
 * with libopus + libogg (BSD, packaged as XCFrameworks by vector-im/opus-swift & ogg-swift, MIT)
 * into a 16-bit WAV file that AVAudioPlayer plays natively.
 */

import Foundation
import YbridOgg
import YbridOpus

enum OpusOggDecoder {
    enum DecodeError: Swift.Error {
        case notOpus, decoderInit(Int32), noAudio
    }

    /// Returns a cached WAV for the given Ogg/Opus file, decoding it on first use.
    static func wavFile(for source: URL, cacheKey: String) throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeKey = cacheKey.replacingOccurrences(of: "/", with: "_")
        let target = dir.appendingPathComponent("\(safeKey).wav")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let data = try Data(contentsOf: source)
        let (pcm, channels) = try decode(data)
        try writeWav(pcm: pcm, channels: channels, sampleRate: 48_000, to: target)
        return target
    }

    /// Decodes Ogg/Opus to interleaved 16-bit PCM at 48 kHz.
    static func decode(_ data: Data) throws -> (pcm: [Int16], channels: Int) {
        var sync = ogg_sync_state()
        var stream = ogg_stream_state()
        var page = ogg_page()
        var packet = ogg_packet()
        ogg_sync_init(&sync)
        defer { ogg_sync_clear(&sync) }

        guard let buffer = ogg_sync_buffer(&sync, data.count) else { throw DecodeError.notOpus }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(buffer, base, data.count) }
        }
        ogg_sync_wrote(&sync, data.count)

        var streamInitialized = false
        var decoder: OpaquePointer?
        var channels: Int32 = 1
        var preSkip = 0
        var packetIndex = 0
        var output: [Int16] = []
        output.reserveCapacity(data.count * 8)
        let maxFrame: Int32 = 5760 // 120 ms at 48 kHz
        var frame = [Float](repeating: 0, count: Int(maxFrame) * 2)

        defer {
            if let decoder { opus_decoder_destroy(decoder) }
            if streamInitialized { ogg_stream_clear(&stream) }
        }

        while ogg_sync_pageout(&sync, &page) == 1 {
            if !streamInitialized {
                ogg_stream_init(&stream, ogg_page_serialno(&page))
                streamInitialized = true
            }
            ogg_stream_pagein(&stream, &page)
            while ogg_stream_packetout(&stream, &packet) == 1 {
                defer { packetIndex += 1 }
                guard let bytes = packet.packet else { continue }
                let length = Int(packet.bytes)
                if packetIndex == 0 {
                    // OpusHead: magic(8) version(1) channels(1) pre-skip(2, LE) rate(4) gain(2) mapping(1)
                    guard length >= 19, memcmp(bytes, "OpusHead", 8) == 0 else { throw DecodeError.notOpus }
                    channels = Int32(max(1, min(2, Int(bytes[9]))))
                    preSkip = Int(bytes[10]) | (Int(bytes[11]) << 8)
                    var err: Int32 = 0
                    decoder = opus_decoder_create(48_000, channels, &err)
                    if decoder == nil || err != 0 { throw DecodeError.decoderInit(err) }
                    continue
                }
                if packetIndex == 1 { continue } // OpusTags
                guard let decoder else { continue }
                let samples = frame.withUnsafeMutableBufferPointer { out in
                    opus_decode_float(decoder, bytes, Int32(length), out.baseAddress!, maxFrame, 0)
                }
                guard samples > 0 else { continue }
                let count = Int(samples) * Int(channels)
                for i in 0..<count {
                    let v = max(-1, min(1, frame[i]))
                    output.append(Int16(v * Float(Int16.max)))
                }
            }
        }
        guard !output.isEmpty else { throw DecodeError.noAudio }
        let skip = min(output.count, preSkip * Int(channels))
        return (Array(output.dropFirst(skip)), Int(channels))
    }

    static func writeWav(pcm: [Int16], channels: Int, sampleRate: Int, to url: URL) throws {
        var data = Data()
        let byteRate = sampleRate * channels * 2
        let dataSize = pcm.count * 2
        func append<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(channels))
        append(UInt32(sampleRate)); append(UInt32(byteRate)); append(UInt16(channels * 2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(dataSize))
        // iOS is little-endian, which is what WAV expects for samples.
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url, options: .atomic)
    }
}
