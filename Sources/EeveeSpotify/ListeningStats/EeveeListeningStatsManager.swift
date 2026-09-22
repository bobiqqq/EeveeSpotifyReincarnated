import Foundation
import UIKit

struct SongPlayRecord: Codable, Identifiable {
    var id: UUID = UUID()
    let trackId: String
    let title: String
    let artist: String
    let playedAt: Date
    let durationSeconds: Double
}

final class EeveeListeningStatsManager {
    static let shared = EeveeListeningStatsManager()
    
    private let queue = DispatchQueue(label: "com.eevee.listeningstats", qos: .utility)
    private var records: [SongPlayRecord] = []
    private let maxAgeDays: Double = 60.0 // 2-month sliding window
    
    // In-flight track tracking
    private var activeTrackId: String = ""
    private var activeTitle: String = ""
    private var activeArtist: String = ""
    private var activeStartedAt: Date = Date()
    private var accumulatedPlayTime: Double = 0.0
    private var lastTickTime: TimeInterval = 0
    private var wasPlaying: Bool = false
    private var hasScrobbledCurrent: Bool = false
    
    private var storageURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("eevee_listening_stats.json")
    }

    private init() {
        loadRecords()
    }

    private func loadRecords() {
        queue.async {
            guard FileManager.default.fileExists(atPath: self.storageURL.path),
                  let data = try? Data(contentsOf: self.storageURL),
                  let loaded = try? JSONDecoder().decode([SongPlayRecord].self, from: data) else {
                return
            }
            self.records = loaded
            self.pruneOldRecordsInternal()
        }
    }

    private func saveRecordsInternal() {
        pruneOldRecordsInternal()
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    private func pruneOldRecordsInternal() {
        let cutoff = Date().addingTimeInterval(-maxAgeDays * 86400)
        records.removeAll { $0.playedAt < cutoff }
    }

    func recordPlaybackTick(trackId: String, title: String, artist: String, isPlaying: Bool, position: Double) {
        guard !title.isEmpty, !artist.isEmpty else { return }
        
        queue.async {
            let now = Date()
            let uptime = ProcessInfo.processInfo.systemUptime
            
            // If track changed
            if (!self.activeTrackId.isEmpty && !trackId.isEmpty && trackId != self.activeTrackId)
                || (!self.activeTitle.isEmpty && title != self.activeTitle) {
                // If previous track was played for >= 30 seconds and not scrobbled yet
                if !self.hasScrobbledCurrent && self.accumulatedPlayTime >= 30.0 && !self.activeTitle.isEmpty {
                    self.commitScrobble(
                        trackId: self.activeTrackId,
                        title: self.activeTitle,
                        artist: self.activeArtist,
                        duration: self.accumulatedPlayTime,
                        at: self.activeStartedAt
                    )
                }
                
                // Reset for new track
                self.activeTrackId = trackId
                self.activeTitle = title
                self.activeArtist = artist
                self.activeStartedAt = now
                self.accumulatedPlayTime = 0.0
                self.hasScrobbledCurrent = false
                self.lastTickTime = uptime
                self.wasPlaying = isPlaying
                return
            }

            if self.activeTitle.isEmpty {
                self.activeTrackId = trackId
                self.activeTitle = title
                self.activeArtist = artist
                self.activeStartedAt = now
            }

            // Accumulate playtime while playing
            if self.wasPlaying && isPlaying && self.lastTickTime > 0 {
                let delta = uptime - self.lastTickTime
                if delta > 0 && delta < 5.0 {
                    self.accumulatedPlayTime += delta
                }
            }
            self.lastTickTime = uptime
            self.wasPlaying = isPlaying

            // Scrobble at 30 seconds threshold
            if !self.hasScrobbledCurrent && self.accumulatedPlayTime >= 30.0 {
                self.hasScrobbledCurrent = true
                self.commitScrobble(
                    trackId: self.activeTrackId,
                    title: self.activeTitle,
                    artist: self.activeArtist,
                    duration: self.accumulatedPlayTime,
                    at: self.activeStartedAt
                )
            }
        }
    }

    private func commitScrobble(trackId: String, title: String, artist: String, duration: Double, at: Date) {
        let record = SongPlayRecord(
            trackId: trackId,
            title: title,
            artist: artist,
            playedAt: at,
            durationSeconds: duration
        )
        records.append(record)
        writeDebugLog("[STATS] Scrobbled track: \(title) - \(artist) (\(Int(duration))s)")
        saveRecordsInternal()
    }

    func getTopTracks(days: Int) -> [(title: String, artist: String, plays: Int, totalDuration: Double)] {
        queue.sync {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
            let filtered = records.filter { $0.playedAt >= cutoff }
            
            var counts: [String: (title: String, artist: String, plays: Int, totalDuration: Double)] = [:]
            for r in filtered {
                let key = "\(r.title) - \(r.artist)".lowercased()
                if var existing = counts[key] {
                    existing.plays += 1
                    existing.totalDuration += r.durationSeconds
                    counts[key] = existing
                } else {
                    counts[key] = (r.title, r.artist, 1, r.durationSeconds)
                }
            }
            return counts.values.sorted { $0.plays > $1.plays }
        }
    }

    func getTopArtists(days: Int) -> [(artist: String, plays: Int, totalDuration: Double)] {
        queue.sync {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
            let filtered = records.filter { $0.playedAt >= cutoff }
            
            var counts: [String: (artist: String, plays: Int, totalDuration: Double)] = [:]
            for r in filtered {
                let key = r.artist.lowercased()
                if var existing = counts[key] {
                    existing.plays += 1
                    existing.totalDuration += r.durationSeconds
                    counts[key] = existing
                } else {
                    counts[key] = (r.artist, 1, r.durationSeconds)
                }
            }
            return counts.values.sorted { $0.plays > $1.plays }
        }
    }

    func getTotalListeningTime(days: Int) -> Double {
        queue.sync {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
            return records.filter { $0.playedAt >= cutoff }.reduce(0) { $0 + $1.durationSeconds }
        }
    }

    func getTotalPlaysCount(days: Int) -> Int {
        queue.sync {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
            return records.filter { $0.playedAt >= cutoff }.count
        }
    }

    func clearAll() {
        queue.async {
            self.records.removeAll()
            try? FileManager.default.removeItem(at: self.storageURL)
            writeDebugLog("[STATS] Listening stats cleared by user")
        }
    }
}
