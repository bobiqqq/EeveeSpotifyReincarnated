import Foundation
import AVFoundation
import UIKit

enum AudioMetadataTagger {
    static func tagM4A(
        inputURL: URL,
        outputURL: URL,
        title: String,
        artist: String,
        album: String,
        artwork: UIImage?,
        completion: @escaping (Bool) -> Void
    ) {
        let asset = AVAsset(url: inputURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            // If passthrough export fails, fallback to direct copy
            try? FileManager.default.copyItem(at: inputURL, to: outputURL)
            completion(true)
            return
        }

        var metadata: [AVMetadataItem] = []

        // Title
        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = .commonIdentifierTitle
        titleItem.value = title as NSString
        metadata.append(titleItem)

        // Artist
        let artistItem = AVMutableMetadataItem()
        artistItem.identifier = .commonIdentifierArtist
        artistItem.value = artist as NSString
        metadata.append(artistItem)

        // Album
        if !album.isEmpty {
            let albumItem = AVMutableMetadataItem()
            albumItem.identifier = .commonIdentifierAlbumName
            albumItem.value = album as NSString
            metadata.append(albumItem)
        }

        // Artwork
        if let art = artwork, let artData = art.jpegData(compressionQuality: 0.85) {
            let artItem = AVMutableMetadataItem()
            artItem.identifier = .commonIdentifierArtwork
            artItem.value = artData as NSData
            artItem.dataType = kCMMetadataBaseDataType_JPEG as String
            metadata.append(artItem)
        }

        try? FileManager.default.removeItem(at: outputURL)
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.metadata = metadata

        exportSession.exportAsynchronously {
            DispatchQueue.main.async {
                if exportSession.status == .completed {
                    completion(true)
                } else {
                    writeDebugLog("[MetadataTagger] Export status: \(exportSession.status.rawValue), error: \(String(describing: exportSession.error))")
                    // Fallback to direct file copy
                    try? FileManager.default.removeItem(at: outputURL)
                    try? FileManager.default.copyItem(at: inputURL, to: outputURL)
                    completion(true)
                }
            }
        }
    }
}
