import Foundation
import UIKit
import MediaPlayer
import AVFoundation
import EeveeSpotifyC

final class EeveeOfflineCoordinator {
    static let shared = EeveeOfflineCoordinator()

    private let queue = DispatchQueue(label: "com.eevee.offline.coordinator", qos: .utility)
    
    private var activeRecordingTrackId: String?
    private var activeRecordingTitle: String = ""
    private var activeRecordingArtist: String = ""
    private var activeRecordingAlbum: String = ""
    private var activeRecordingDuration: Double = 0
    private var activeRecordingTempPath: String?
    private var accumulatedRecordedSeconds: Double = 0
    private var lastRecordedUptime: TimeInterval = 0
    private var hasFinalizedCurrentTrack: Bool = false

    private init() {}

    func handlePlaybackUpdate(
        trackId: String,
        title: String,
        artist: String,
        album: String,
        isPlaying: Bool,
        position: Double,
        duration: Double
    ) {
        guard EeveeOfflineStorageManager.shared.isAutoCacheEnabled else {
            if EeveeIsAudioRecording() {
                EeveeStopAudioRecording()
            }
            return
        }

        guard !trackId.isEmpty, !title.isEmpty else { return }

        queue.async {
            let nowUptime = ProcessInfo.processInfo.systemUptime

            // Check if track changed
            if let currentId = self.activeRecordingTrackId, currentId != trackId {
                self.finishRecordingIfNeeded()
            }

            // If already downloaded, do nothing
            if EeveeOfflineStorageManager.shared.isTrackDownloaded(trackId: trackId) {
                return
            }

            // Start new recording session
            if self.activeRecordingTrackId != trackId {
                self.activeRecordingTrackId = trackId
                self.activeRecordingTitle = title
                self.activeRecordingArtist = artist
                self.activeRecordingAlbum = album
                self.activeRecordingDuration = duration
                self.accumulatedRecordedSeconds = 0
                self.hasFinalizedCurrentTrack = false
                self.lastRecordedUptime = nowUptime

                let tempFileName = "temp_\(trackId).m4a"
                let tempURL = EeveeOfflineStorageManager.shared.activeStorageURL.appendingPathComponent(tempFileName)
                self.activeRecordingTempPath = tempURL.path

                if isPlaying {
                    EeveeStartAudioRecording(tempURL.path)
                }
                return
            }

            // Accumulate playback time while recording
            if isPlaying && self.lastRecordedUptime > 0 {
                let delta = nowUptime - self.lastRecordedUptime
                if delta > 0 && delta < 5.0 {
                    self.accumulatedRecordedSeconds += delta
                }
            }
            self.lastRecordedUptime = nowUptime

            // Auto-pause / resume recording based on player state
            if !isPlaying && EeveeIsAudioRecording() {
                EeveeStopAudioRecording()
            } else if isPlaying && !EeveeIsAudioRecording() && !self.hasFinalizedCurrentTrack {
                if let path = self.activeRecordingTempPath {
                    EeveeStartAudioRecording(path)
                }
            }

            // Check if track reached enough duration to finalize (e.g. >= 90% of duration or at track transition)
            let threshold = duration > 10 ? (duration * 0.90) : 20.0
            if !self.hasFinalizedCurrentTrack && self.accumulatedRecordedSeconds >= threshold {
                self.finishRecordingIfNeeded()
            }
        }
    }

    private func finishRecordingIfNeeded() {
        guard let trackId = activeRecordingTrackId,
              let tempPath = activeRecordingTempPath,
              !hasFinalizedCurrentTrack else {
            return
        }

        hasFinalizedCurrentTrack = true
        EeveeStopAudioRecording()

        let fm = FileManager.default
        guard fm.fileExists(atPath: tempPath) else { return }

        // Validate that the file has real audio content (at least 100 KB)
        let attributes = try? fm.attributesOfItem(atPath: tempPath)
        let size = (attributes?[.size] as? Int64) ?? 0
        guard size > 100 * 1024 else {
            writeDebugLog("[OfflineCoordinator] Recording was too short (\(size) bytes) — discarding")
            try? fm.removeItem(atPath: tempPath)
            activeRecordingTrackId = nil
            activeRecordingTempPath = nil
            return
        }

        let cleanTitle = self.activeRecordingTitle.isEmpty ? "Track" : self.activeRecordingTitle
        let cleanArtist = self.activeRecordingArtist.isEmpty ? "Artist" : self.activeRecordingArtist
        let trackKey = "\(cleanArtist)_\(cleanTitle)".replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
        let finalFileName = "\(trackKey).m4a"
        let finalURL = EeveeOfflineStorageManager.shared.activeStorageURL.appendingPathComponent(finalFileName)

        try? fm.removeItem(at: finalURL)
        do {
            try fm.moveItem(atPath: tempPath, toPath: finalURL.path)
            
            EeveeOfflineStorageManager.shared.registerDownloadedTrack(
                trackId: trackId,
                title: cleanTitle,
                artist: cleanArtist,
                album: self.activeRecordingAlbum,
                duration: self.activeRecordingDuration,
                fileName: finalFileName
            )

            let sizeMB = String(format: "%.1f", Double(size) / (1024.0 * 1024.0))
            writeDebugLog("[OfflineCoordinator] Successfully saved full track: \(cleanTitle) - \(cleanArtist) (\(sizeMB) MB)")
            
            DispatchQueue.main.async {
                SponsorBlockToast.shared.show("✓ Сохранен полный трек (\(sizeMB) МБ): \(cleanTitle)")
            }
        } catch {
            writeDebugLog("[OfflineCoordinator] Failed to finalize offline track file: \(error)")
        }

        activeRecordingTrackId = nil
        activeRecordingTempPath = nil
    }
}
