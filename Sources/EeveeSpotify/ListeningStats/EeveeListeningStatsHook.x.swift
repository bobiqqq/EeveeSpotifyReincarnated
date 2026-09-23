import Orion
import MediaPlayer

class MPNowPlayingInfoCenterStatsHook: ClassHook<MPNowPlayingInfoCenter> {
    func setNowPlayingInfo(_ info: [String: Any]?) {
        orig.setNowPlayingInfo(info)
        guard let info = info else { return }

        let title = info[MPMediaItemPropertyTitle] as? String ?? ""
        let artist = info[MPMediaItemPropertyArtist] as? String ?? ""
        let duration = (info[MPMediaItemPropertyPlaybackDuration] as? NSNumber)?.doubleValue ?? 0
        let playbackRate = (info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue ?? 0
        let elapsed = (info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue ?? 0
        let isPlaying = playbackRate > 0

        EeveeDiagnosticsManager.shared.updatePlayback(
            title: title,
            artist: artist,
            trackId: capturedTrackId,
            isPlaying: isPlaying,
            position: elapsed,
            duration: duration
        )

        EeveeListeningStatsManager.shared.recordPlaybackTick(
            trackId: capturedTrackId ?? "",
            title: title,
            artist: artist,
            isPlaying: isPlaying,
            position: elapsed
        )

        if let trackId = capturedTrackId, !trackId.isEmpty {
            prefetchLyricsIfNeeded(trackId: trackId)
        }
    }
}
