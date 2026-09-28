import Foundation
import UIKit
import MobileCoreServices
import UniformTypeIdentifiers

struct OfflineTrackInfo: Codable, Identifiable {
    var id: String { trackId }
    let trackId: String
    let title: String
    let artist: String
    let album: String
    let durationSeconds: Double
    let downloadedAt: Date
    let fileSize: Int64
    let relativeFileName: String
}

final class EeveeOfflineStorageManager {
    static let shared = EeveeOfflineStorageManager()

    private let bookmarkKey = "eevee_offline_storage_bookmark"
    private let autoCacheEnabledKey = "eevee_offline_auto_cache_enabled"
    private let indexFileName = "offline_index.json"
    
    private let lock = NSLock()
    private var cachedTracks: [String: OfflineTrackInfo] = [:]
    private var securityScopedURL: URL?

    var isAutoCacheEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: autoCacheEnabledKey) as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoCacheEnabledKey)
        }
    }

    private init() {
        restoreSecurityScopedBookmark()
        createDefaultDirectoriesIfNeeded()
        loadIndex()
    }

    // MARK: - Directory Resolution

    private var defaultDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("OfflineMusic", isDirectory: true)
    }

    var activeStorageURL: URL {
        if let customURL = securityScopedURL {
            return customURL
        }
        return defaultDirectory
    }

    var isUsingCustomExternalFolder: Bool {
        securityScopedURL != nil
    }

    private func createDefaultDirectoriesIfNeeded() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: defaultDirectory.path) {
            try? fm.createDirectory(at: defaultDirectory, withIntermediateDirectories: true, attributes: nil)
        }
    }

    // MARK: - Security-Scoped Bookmark (Permanent Files.app Folder)

    func setCustomFolder(url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            writeDebugLog("[OfflineStorage] Failed to start accessing security-scoped resource: \(url.path)")
            return
        }

        do {
            let bookmarkData = try url.bookmarkData(
                options: .suitableForBookmarkFile,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
            self.securityScopedURL = url
            writeDebugLog("[OfflineStorage] Custom external folder configured: \(url.path)")
            loadIndex()
        } catch {
            writeDebugLog("[OfflineStorage] Failed to create bookmark data: \(error)")
        }
    }

    func resetToDefaultFolder() {
        if let url = securityScopedURL {
            url.stopAccessingSecurityScopedResource()
            self.securityScopedURL = nil
        }
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        loadIndex()
    }

    private func restoreSecurityScopedBookmark() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var isStale = false
        do {
            let restoredURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if restoredURL.startAccessingSecurityScopedResource() {
                self.securityScopedURL = restoredURL
                writeDebugLog("[OfflineStorage] Restored custom external storage: \(restoredURL.path)")
            }
        } catch {
            writeDebugLog("[OfflineStorage] Could not restore bookmark: \(error)")
        }
    }

    // MARK: - Track Index Management

    private func loadIndex() {
        lock.lock()
        defer { lock.unlock() }

        let indexURL = activeStorageURL.appendingPathComponent(indexFileName)
        guard FileManager.default.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: indexURL),
              let items = try? JSONDecoder().decode([String: OfflineTrackInfo].self, from: data) else {
            cachedTracks = [:]
            return
        }
        cachedTracks = items
    }

    private func saveIndexInternal() {
        let indexURL = activeStorageURL.appendingPathComponent(indexFileName)
        if let data = try? JSONEncoder().encode(cachedTracks) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    func isTrackDownloaded(trackId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let info = cachedTracks[trackId] else { return false }
        let filePath = activeStorageURL.appendingPathComponent(info.relativeFileName).path
        return FileManager.default.fileExists(atPath: filePath)
    }

    func localFileURL(for trackId: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let info = cachedTracks[trackId] else { return nil }
        let fileURL = activeStorageURL.appendingPathComponent(info.relativeFileName)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        return nil
    }

    func registerDownloadedTrack(
        trackId: String,
        title: String,
        artist: String,
        album: String,
        duration: Double,
        fileName: String
    ) {
        lock.lock()
        defer { lock.unlock() }

        let fileURL = activeStorageURL.appendingPathComponent(fileName)
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0

        let track = OfflineTrackInfo(
            trackId: trackId,
            title: title,
            artist: artist,
            album: album,
            durationSeconds: duration,
            downloadedAt: Date(),
            fileSize: size,
            relativeFileName: fileName
        )

        cachedTracks[trackId] = track
        saveIndexInternal()
        
        // Expose to Spotify Documents for native Local Files scanner
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let cleanName = "\(artist) - \(title).m4a".replacingOccurrences(of: "/", with: "_")
        let docMirrorURL = docs.appendingPathComponent(cleanName)
        try? FileManager.default.removeItem(at: docMirrorURL)
        try? FileManager.default.copyItem(at: fileURL, to: docMirrorURL)
        
        writeDebugLog("[OfflineStorage] Registered track: \(title) by \(artist) (\(size / 1024) KB)")
    }

    func deleteTrack(trackId: String) {
        lock.lock()
        defer { lock.unlock() }

        guard let info = cachedTracks.removeValue(forKey: trackId) else { return }
        let fileURL = activeStorageURL.appendingPathComponent(info.relativeFileName)
        try? FileManager.default.removeItem(at: fileURL)
        
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let cleanName = "\(info.artist) - \(info.title).m4a".replacingOccurrences(of: "/", with: "_")
        try? FileManager.default.removeItem(at: docs.appendingPathComponent(cleanName))
        
        saveIndexInternal()
    }

    func deleteAllTracks() {
        lock.lock()
        defer { lock.unlock() }

        for (_, info) in cachedTracks {
            let fileURL = activeStorageURL.appendingPathComponent(info.relativeFileName)
            try? FileManager.default.removeItem(at: fileURL)
        }
        cachedTracks.removeAll()
        saveIndexInternal()
    }

    func allTracks() -> [OfflineTrackInfo] {
        lock.lock()
        defer { lock.unlock() }
        return Array(cachedTracks.values).sorted { $0.downloadedAt > $1.downloadedAt }
    }

    var totalStorageSize: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return cachedTracks.values.reduce(0) { $0 + $1.fileSize }
    }
}
