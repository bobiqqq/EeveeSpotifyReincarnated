import Foundation
import UIKit

final class EeveeDiagnosticsManager {
    static let shared = EeveeDiagnosticsManager()
    
    private let lock = NSLock()
    
    private(set) var lastLyricsProvider: String = "None yet"
    private(set) var lastLyricsStatus: String = "No requests"
    private(set) var currentTrackTitle: String = "Not playing"
    private(set) var currentArtist: String = "Not playing"
    private(set) var currentTrackId: String = "-"
    private(set) var playbackState: String = "Stopped"
    private(set) var playbackPosition: String = "0:00 / 0:00"

    private init() {}

    func recordLyrics(source: String, status: String) {
        lock.lock()
        defer { lock.unlock() }
        self.lastLyricsProvider = source
        self.lastLyricsStatus = status
    }

    func updatePlayback(title: String, artist: String, trackId: String?, isPlaying: Bool, position: Double, duration: Double) {
        lock.lock()
        defer { lock.unlock() }
        if !title.isEmpty { self.currentTrackTitle = title }
        if !artist.isEmpty { self.currentArtist = artist }
        if let tid = trackId, !tid.isEmpty { self.currentTrackId = tid }
        self.playbackState = isPlaying ? "Playing" : "Paused"
        
        let posMin = Int(position) / 60
        let posSec = Int(position) % 60
        let durMin = Int(duration) / 60
        let durSec = Int(duration) % 60
        self.playbackPosition = String(format: "%d:%02d / %d:%02d", posMin, posSec, durMin, durSec)
    }

    var spotifyVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    var eeveeVersion: String {
        "\(EeveeSpotify.version) (Build \(EeveeSpotify.buildNumber))"
    }

    var systemInfo: String {
        let systemVersion = UIDevice.current.systemVersion
        let model = UIDevice.current.model
        return "\(model), iOS \(systemVersion)"
    }

    var patchTypeDescription: String {
        switch UserDefaults.patchType {
        case .notSet: return "Not Set"
        case .disabled: return "Disabled"
        case .requests: return "Requests"
        }
    }

    func buildFullReport() -> String {
        lock.lock()
        let title = currentTrackTitle
        let artist = currentArtist
        let tid = currentTrackId
        let playState = playbackState
        let playPos = playbackPosition
        let lyricsSource = lastLyricsProvider
        let lyricsStat = lastLyricsStatus
        lock.unlock()

        var report = """
        === EeveeSpotify Diagnostics Report ===
        Date: \(Date())
        Device: \(systemInfo)
        Spotify Version: \(spotifyVersion)
        Eevee Version: \(eeveeVersion)
        Patch Type: \(patchTypeDescription)
        Overwrite Config: \(UserDefaults.overwriteConfiguration ? "Enabled" : "Disabled")
        
        [Current Playback]
        Track: \(title)
        Artist: \(artist)
        Track ID: \(tid)
        State: \(playState) (\(playPos))
        
        [Lyrics]
        Configured Source: \(UserDefaults.lyricsSource.description)
        Last Provider Used: \(lyricsSource)
        Last Fetch Status: \(lyricsStat)
        
        [Latest Debug Logs]
        """
        
        let logPath = NSTemporaryDirectory() + "eeveespotify_debug.log"
        if let logContent = try? String(contentsOfFile: logPath, encoding: .utf8) {
            let lines = logContent.components(separatedBy: .newlines)
            let tail = lines.suffix(60).joined(separator: "\n")
            report += "\n" + tail
        } else {
            report += "\n<No log file found>"
        }

        return report
    }
}
