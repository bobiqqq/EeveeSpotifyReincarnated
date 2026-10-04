import Foundation
import UIKit
import MediaPlayer
import AVFoundation
import EeveeSpotifyC

final class EeveeOfflineCoordinator {
    static let shared = EeveeOfflineCoordinator()

    private let queue = DispatchQueue(label: "com.eevee.offline.coordinator", qos: .utility)
    
    // Explicit manual download state
    private var targetTrackId: String?
    private var targetTitle: String = ""
    private var targetArtist: String = ""
    private var targetAlbum: String = ""
    private var targetDuration: Double = 0
    private var recordingTempPath: String?
    private var accumulatedSeconds: Double = 0
    private var lastTickUptime: TimeInterval = 0
    private var isRecordingThisTrack: Bool = false

    private init() {}

    /// Triggered explicitly by the user (Context Menu or Settings)
    func startManualDownload(
        trackId: String,
        title: String,
        artist: String,
        album: String = "",
        duration: Double = 0
    ) {
        guard !title.isEmpty, title != "Not playing" else {
            PopUpHelper.showPopUp(message: "Включите трек в плеере Spotify!", buttonText: "OK".uiKitLocalized)
            return
        }

        queue.async {
            let trackKey = "\(artist)_\(title)".replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
            let idToUse = trackId.isEmpty ? trackKey : trackId

            // If already downloaded
            if EeveeOfflineStorageManager.shared.isTrackDownloaded(trackId: idToUse) ||
               EeveeOfflineStorageManager.shared.isTrackDownloaded(trackId: trackKey) {
                DispatchQueue.main.async {
                    SponsorBlockToast.shared.show("✓ Трек уже есть в офлайне: \(title)")
                }
                return
            }

            // Stop any previous recording
            self.cancelRecordingInternal()

            self.targetTrackId = idToUse
            self.targetTitle = title
            self.targetArtist = artist
            self.targetAlbum = album
            self.targetDuration = duration
            self.accumulatedSeconds = 0
            self.lastTickUptime = ProcessInfo.processInfo.systemUptime

            let tempFileName = "temp_\(trackKey).m4a"
            let tempURL = EeveeOfflineStorageManager.shared.activeStorageURL.appendingPathComponent(tempFileName)
            self.recordingTempPath = tempURL.path

            EeveeStartAudioRecording(tempURL.path)
            self.isRecordingThisTrack = true

            writeDebugLog("[OfflineCoordinator] Manual recording started for: \(title) by \(artist)")
            DispatchQueue.main.async {
                SponsorBlockToast.shared.show("🔴 Запись в офлайн: «\(title)». Дослушайте трек для сохранения.")
            }
        }
    }

    /// Called by MPNowPlayingInfoCenterDiagnosticsHook on playback ticks
    func handlePlaybackUpdate(
        trackId: String,
        title: String,
        artist: String,
        album: String,
        isPlaying: Bool,
        position: Double,
        duration: Double
    ) {
        queue.async {
            guard self.isRecordingThisTrack, let activeId = self.targetTrackId else { return }

            let trackKey = "\(artist)_\(title)".replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
            let matches = (trackId == activeId) || (title == self.targetTitle && artist == self.targetArtist) || (trackKey == activeId)

            let nowUptime = ProcessInfo.processInfo.systemUptime

            // Track changed away before completing
            if !matches {
                writeDebugLog("[OfflineCoordinator] User switched track away from \(self.targetTitle). Finalizing if enough recorded.")
                self.finishRecordingInternal()
                return
            }

            if self.targetDuration <= 0 && duration > 0 {
                self.targetDuration = duration
            }

            // Accumulate playtime
            if isPlaying && self.lastTickUptime > 0 {
                let delta = nowUptime - self.lastTickUptime
                if delta > 0 && delta < 5.0 {
                    self.accumulatedSeconds += delta
                }
            }
            self.lastTickUptime = nowUptime

            // If user paused, pause recording
            if !isPlaying && EeveeIsAudioRecording() {
                EeveeStopAudioRecording()
            } else if isPlaying && !EeveeIsAudioRecording() {
                if let path = self.recordingTempPath {
                    EeveeStartAudioRecording(path)
                }
            }

            // If reached near end (>= 85% of track duration)
            if self.targetDuration > 15 && self.accumulatedSeconds >= (self.targetDuration * 0.85) {
                self.finishRecordingInternal()
            }
        }
    }

    private func finishRecordingInternal() {
        guard isRecordingThisTrack,
              let trackId = targetTrackId,
              let tempPath = recordingTempPath else {
            return
        }

        isRecordingThisTrack = false
        EeveeStopAudioRecording()

        let fm = FileManager.default
        guard fm.fileExists(atPath: tempPath) else {
            resetTarget()
            return
        }

        let attributes = try? fm.attributesOfItem(atPath: tempPath)
        let size = (attributes?[.size] as? Int64) ?? 0

        // Minimum valid audio size (at least 150 KB)
        guard size > 150 * 1024 else {
            writeDebugLog("[OfflineCoordinator] Recording was too short (\(size) bytes) — cancelled")
            try? fm.removeItem(atPath: tempPath)
            resetTarget()
            return
        }

        let cleanTitle = targetTitle.isEmpty ? "Track" : targetTitle
        let cleanArtist = targetArtist.isEmpty ? "Artist" : targetArtist
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
                album: self.targetAlbum,
                duration: self.targetDuration,
                fileName: finalFileName
            )

            let sizeMB = String(format: "%.1f", Double(size) / (1024.0 * 1024.0))
            writeDebugLog("[OfflineCoordinator] Successfully saved full track: \(cleanTitle) - \(cleanArtist) (\(sizeMB) MB)")
            
            DispatchQueue.main.async {
                SponsorBlockToast.shared.show("✓ Сохранен в «Добавленные файлы» (\(sizeMB) МБ): \(cleanTitle)")
            }
        } catch {
            writeDebugLog("[OfflineCoordinator] Failed to move file: \(error)")
        }

        resetTarget()
    }

    private func cancelRecordingInternal() {
        if isRecordingThisTrack {
            isRecordingThisTrack = false
            EeveeStopAudioRecording()
            if let path = recordingTempPath {
                try? FileManager.default.removeItem(atPath: path)
            }
            resetTarget()
        }
    }

    private func resetTarget() {
        targetTrackId = nil
        targetTitle = ""
        targetArtist = ""
        targetAlbum = ""
        targetDuration = 0
        recordingTempPath = nil
        accumulatedSeconds = 0
        lastTickUptime = 0
    }
}
