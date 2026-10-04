import Foundation
import Observation

/// Tracks TDLib file downloads (updateFile) for the UI.
/// Only completed paths and the progress of files the UI explicitly watches are published,
/// so a stream of updateFile chunks does not re-render every image on screen.
@MainActor
@Observable
final class FileStore {
    /// fileId → local path of a fully downloaded file.
    private(set) var paths: [Int: String] = [:]
    /// fileId → 0…1 progress, only for files that are being downloaded on request.
    private(set) var progress: [Int: Double] = [:]

    @ObservationIgnored private var requested: Set<Int> = []
    @ObservationIgnored var downloader: ((Int, Int) -> Void)?   // (fileId, priority)
    @ObservationIgnored var canceller: ((Int) -> Void)?

    func path(for file: FileRef?) -> String? {
        guard let file else { return nil }
        if let p = paths[file.id] { return p }
        if file.isLocal { return file.localPath }
        return nil
    }

    func isDownloading(_ file: FileRef) -> Bool { progress[file.id] != nil }

    /// Starts a download unless the file is already local or requested. Priority 1…32.
    func request(_ file: FileRef?, priority: Int = 1) {
        guard let file, file.id != 0, path(for: file) == nil, !requested.contains(file.id) else { return }
        requested.insert(file.id)
        downloader?(file.id, priority)
    }

    /// User-initiated download with visible progress.
    func download(_ file: FileRef) {
        guard path(for: file) == nil else { return }
        progress[file.id] = 0
        requested.insert(file.id)
        downloader?(file.id, 32)
    }

    func cancel(_ file: FileRef) {
        progress[file.id] = nil
        requested.remove(file.id)
        canceller?(file.id)
    }

    func update(id: Int, localPath: String?, completed: Bool, downloaded: Int64, size: Int64, isActive: Bool) {
        if completed, let localPath, !localPath.isEmpty {
            if paths[id] != localPath { paths[id] = localPath }
            if progress[id] != nil { progress[id] = nil }
            return
        }
        if progress[id] != nil {
            if !isActive && downloaded == 0 {
                progress[id] = nil
                requested.remove(id)
            } else if size > 0 {
                progress[id] = Double(downloaded) / Double(size)
            }
        }
        if !isActive && !completed { requested.remove(id) }
    }

    func reset() {
        paths = [:]
        progress = [:]
        requested = []
    }
}
