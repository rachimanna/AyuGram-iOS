import AVFoundation
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct ImportedVideo: Transferable {
    var url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let target = ChatViewModel.outgoingDirectory.appendingPathComponent(UUID().uuidString + "." + received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: target)
            return ImportedVideo(url: target)
        }
    }
}

struct PreparedVideo {
    var url: URL
    var width: Int
    var height: Int
    var duration: Int
}

enum OutgoingVideo {
    static func prepare(_ source: URL) async throws -> PreparedVideo {
        let asset = AVURLAsset(url: source)
        guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty,
              let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            throw ChatFeatureError.videoExportFailed
        }
        let target = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mp4")
        exporter.outputURL = target
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { continuation.resume() }
        }
        guard exporter.status == .completed else {
            try? FileManager.default.removeItem(at: target)
            throw exporter.error ?? ChatFeatureError.videoExportFailed
        }
        let encoded = AVURLAsset(url: target)
        guard let encodedTrack = try await encoded.loadTracks(withMediaType: .video).first else {
            try? FileManager.default.removeItem(at: target)
            throw ChatFeatureError.videoExportFailed
        }
        let naturalSize = try await encodedTrack.load(.naturalSize)
        let transform = try await encodedTrack.load(.preferredTransform)
        let size = naturalSize.applying(transform)
        let duration = try await encoded.load(.duration)
        return PreparedVideo(url: target, width: Int(abs(size.width)), height: Int(abs(size.height)),
                             duration: max(1, Int(ceil(CMTimeGetSeconds(duration)))))
    }
}
