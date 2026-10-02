import Foundation

enum Storage {
    /// Where downloaded playlists and guides are kept. tvOS only lets apps write to Caches,
    /// which the system may empty; everything stored here can be downloaded again.
    static var directory: URL {
        #if os(tvOS)
        let base = FileManager.SearchPathDirectory.cachesDirectory
        #else
        let base = FileManager.SearchPathDirectory.applicationSupportDirectory
        #endif
        let directory = FileManager.default.urls(for: base, in: .userDomainMask)[0]
            .appendingPathComponent("Playa", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
