import Orion
import UIKit
import EeveeSpotifyC

class ContextMenuOfflineHook: ClassHook<UIViewController> {
    static var targetName: String {
        if NSClassFromString("_TtC24ContextMenu_InternalImpl25ContextMenuViewController") != nil {
            return "_TtC24ContextMenu_InternalImpl25ContextMenuViewController"
        }
        return "UIViewController"
    }

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        
        let clsName = NSStringFromClass(type(of: target))
        guard clsName.contains("ContextMenuViewController") else { return }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak target] in
            guard let target = target else { return }
            self.attachOfflineActionButton(to: target)
        }
    }

    private func attachOfflineActionButton(to vc: UIViewController) {
        // Find labels to determine track title and artist
        var titleText: String?
        var artistText: String?
        
        func findLabels(in view: UIView) {
            if let label = view as? UILabel, let text = label.text, !text.isEmpty {
                if titleText == nil {
                    titleText = text
                } else if artistText == nil {
                    artistText = text
                }
            }
            for sub in view.subviews {
                findLabels(in: sub)
            }
        }
        
        findLabels(in: vc.view)
        
        guard let title = titleText, !title.isEmpty else { return }
        let artist = artistText ?? ""
        
        // Prevent duplicate button injection
        let buttonTag = 948271
        if vc.view.viewWithTag(buttonTag) != nil { return }
        
        let trackId = capturedTrackId ?? UUID().uuidString
        let isDownloaded = EeveeOfflineStorageManager.shared.isTrackDownloaded(trackId: trackId)
        
        // Find main container to insert our action row
        let buttonContainer = UIButton(type: .system)
        buttonContainer.tag = buttonTag
        buttonContainer.backgroundColor = UIColor(white: 0.15, alpha: 0.95)
        buttonContainer.layer.cornerRadius = 10
        buttonContainer.clipsToBounds = true
        
        let icon = UIImage(systemName: isDownloaded ? "trash.fill" : "arrow.down.circle.fill")
        buttonContainer.setImage(icon, for: .normal)
        buttonContainer.tintColor = isDownloaded ? .systemRed : .systemGreen
        buttonContainer.setTitle(isDownloaded ? "  Удалить из офлайна" : "  Скачать в офлайн", for: .normal)
        buttonContainer.setTitleColor(.white, for: .normal)
        buttonContainer.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        
        buttonContainer.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(buttonContainer)
        
        NSLayoutConstraint.activate([
            buttonContainer.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 16),
            buttonContainer.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -16),
            buttonContainer.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor, constant: 8),
            buttonContainer.heightAnchor.constraint(equalToConstant: 44)
        ])
        
        buttonContainer.addAction(UIAction { [weak vc] _ in
            if isDownloaded {
                EeveeOfflineStorageManager.shared.deleteTrack(trackId: trackId)
                SponsorBlockToast.shared.show("✓ Удалено из офлайна: \(title)")
            } else {
                let fileName = "\(trackId).m4a"
                let targetURL = EeveeOfflineStorageManager.shared.activeStorageURL.appendingPathComponent(fileName)
                EeveeStartAudioRecording(targetURL.path)
                
                EeveeOfflineStorageManager.shared.registerDownloadedTrack(
                    trackId: trackId,
                    title: title,
                    artist: artist,
                    album: "",
                    duration: 0,
                    fileName: fileName
                )
                SponsorBlockToast.shared.show(" Загрузка трека в офлайн: \(title)")
            }
            vc?.dismiss(animated: true)
        }, for: .touchUpInside)
    }
}
