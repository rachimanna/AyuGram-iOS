/*
 * Port of AyuConstants.java (Copyright @Radolyn, 2023, GPL-2.0).
 */

import Foundation

enum AyuConstants {
    /// @ayugramchat, @ayugram1338, @radolyn — Bot-API-style ids from the Android source.
    static let officialChannels: [Int64] = [1905581924, 1794457129, 1434550607]
    /// @alexeyzavar, @sharapagorg, @Zanko_no_tachi, @MaxPlays, @radolyn_services
    static let devs: [Int64] = [139303278, 778327202, 963494570, 238292700, 1795176335]

    static let documentTypeNone = 0
    static let documentTypePhoto = 1
    static let documentTypeSticker = 2
    static let documentTypeFile = 3

    static let defaultDeletedMark = "🧹"
    static let defaultAyuSyncServer = "ayusync.cloud"

    static let ayuDatabase = "ayu-data"
    static let attachmentsSubfolder = "Saved Attachments"
    static let appGitHub = "AyuGram/AyuGram4A"
    static let appName = "AyuGram"

    static let backgroundRefreshTaskId = "com.ayugram.port.refresh"

    /// Root for files the user may want to see in the Files app (Android: Downloads/AyuGram).
    static var attachmentsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(attachmentsSubfolder, isDirectory: true)
    }

    static var applicationSupport: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Localized string lookup (Localizable.strings, keys mirror Android string ids).
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Localized format string lookup.
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}
