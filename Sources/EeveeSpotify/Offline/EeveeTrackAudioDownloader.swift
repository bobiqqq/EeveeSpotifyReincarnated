import Foundation
import UIKit
import AVFoundation
import EeveeSpotifyC

final class EeveeTrackAudioDownloader {
    static let shared = EeveeTrackAudioDownloader()

    private let session: URLSession
    private let queue = DispatchQueue(label: "com.eevee.offline.downloader", qos: .userInitiated)

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    func downloadTrack(
        trackId: String,
        title: String,
        artist: String,
        album: String = "",
        onComplete: ((Bool) -> Void)? = nil
    ) {
        guard !title.isEmpty else {
            onComplete?(false)
            return
        }

        queue.async {
            writeDebugLog("[Downloader] Starting download for: \(title) by \(artist)")
            DispatchQueue.main.async {
                SponsorBlockToast.shared.show(" Загрузка: \(title)...")
            }

            // Clean search query
            let cleanTitle = title.replacingOccurrences(of: "(feat.*)", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\[.*\\]", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let cleanArtist = artist.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? artist
            let query = "\(cleanTitle) \(cleanArtist)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cleanTitle

            // Query iTunes Audio API
            let itunesURLString = "https://itunes.apple.com/search?term=\(query)&entity=song&limit=1"
            guard let itunesURL = URL(string: itunesURLString) else {
                self.fallbackToAudioUnit(trackId: trackId, title: title, artist: artist, album: album)
                onComplete?(false)
                return
            }

            var request = URLRequest(url: itunesURL)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

            let semaphore = DispatchSemaphore(value: 0)
            var audioStreamURLString: String?
            var artworkURLString: String?
            var resolvedAlbum = album

            self.session.dataTask(with: request) { data, _, error in
                defer { semaphore.signal() }
                guard let data = data, error == nil,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["results"] as? [[String: Any]],
                      let first = results.first else {
                    return
                }

                audioStreamURLString = first["previewUrl"] as? String
                artworkURLString = first["artworkUrl100"] as? String
                if resolvedAlbum.isEmpty {
                    resolvedAlbum = first["collectionName"] as? String ?? ""
                }
            }.resume()

            semaphore.wait()

            guard let streamURLString = audioStreamURLString, let streamURL = URL(string: streamURLString) else {
                writeDebugLog("[Downloader] No online stream URL found, switching to live recorder")
                self.fallbackToAudioUnit(trackId: trackId, title: title, artist: artist, album: album)
                onComplete?(false)
                return
            }

            // Download audio data
            var audioData: Data?
            let audioSemaphore = DispatchSemaphore(value: 0)

            self.session.dataTask(with: streamURL) { data, _, error in
                defer { audioSemaphore.signal() }
                if let data = data, error == nil, data.count > 10000 {
                    audioData = data
                }
            }.resume()

            audioSemaphore.wait()

            guard let data = audioData else {
                writeDebugLog("[Downloader] Audio download failed")
                self.fallbackToAudioUnit(trackId: trackId, title: title, artist: artist, album: album)
                onComplete?(false)
                return
            }

            // Save file
            let trackKey = "\(artist)_\(title)".replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
            let fileName = "\(trackKey).m4a"
            let targetURL = EeveeOfflineStorageManager.shared.activeStorageURL.appendingPathComponent(fileName)

            do {
                try data.write(to: targetURL, options: .atomic)
                
                EeveeOfflineStorageManager.shared.registerDownloadedTrack(
                    trackId: trackKey,
                    title: title,
                    artist: artist,
                    album: resolvedAlbum,
                    duration: 0,
                    fileName: fileName
                )

                let sizeMB = String(format: "%.1f", Double(data.count) / (1024.0 * 1024.0))
                writeDebugLog("[Downloader] Successfully downloaded \(title) (\(sizeMB) MB)")
                
                DispatchQueue.main.async {
                    SponsorBlockToast.shared.show("✓ Скачано в «Добавленные файлы»: \(title) (\(sizeMB) МБ)")
                }
                onComplete?(true)
            } catch {
                writeDebugLog("[Downloader] Save failed: \(error)")
                onComplete?(false)
            }
        }
    }

    private func fallbackToAudioUnit(trackId: String, title: String, artist: String, album: String) {
        let trackKey = "\(artist)_\(title)".replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
        let fileName = "\(trackKey).m4a"
        let targetURL = EeveeOfflineStorageManager.shared.activeStorageURL.appendingPathComponent(fileName)
        
        EeveeStartAudioRecording(targetURL.path)
        DispatchQueue.main.async {
            SponsorBlockToast.shared.show(" Включите трек: запись потока в офлайн...")
        }
    }
}
