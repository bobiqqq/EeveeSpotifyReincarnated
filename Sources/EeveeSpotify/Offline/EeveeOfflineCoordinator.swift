import Foundation
import UIKit
import MediaPlayer
import AVFoundation

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

            // Check if track reached enough duration to finalize (e.g. >= 85% or >= 30s)
            let threshold = duration > 10 ? min(duration * 0.85, 30.0) : 15.0
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

        let finalFileName = "\(trackId).m4a"
        let finalURL = EeveeOfflineStorageManager.shared.activeStorageURL.appendingPathComponent(finalFileName)

        try? fm.removeItem(at: finalURL)
        do {
            try fm.moveItem(atPath: tempPath, toPath: finalURL.path)
            
            EeveeOfflineStorageManager.shared.registerDownloadedTrack(
                trackId: trackId,
                title: self.activeRecordingTitle,
                artist: self.activeRecordingArtist,
                album: self.activeRecordingAlbum,
                duration: self.activeRecordingDuration,
                fileName: finalFileName
            )

            writeDebugLog("[OfflineCoordinator] Successfully saved offline track: \(self.activeRecordingTitle) - \(self.activeRecordingArtist)")
            
            DispatchQueue.main.async {
                SponsorBlockToast.shared.show("✓ Трек сохранён в офлайн: \(self.activeRecordingTitle)")
            }
        } catch {
            writeDebugLog("[OfflineCoordinator] Failed to finalize offline track file: \(error)")
        }

        activeRecordingTrackId = nil
        activeRecordingTempPath = nil
    }
}
