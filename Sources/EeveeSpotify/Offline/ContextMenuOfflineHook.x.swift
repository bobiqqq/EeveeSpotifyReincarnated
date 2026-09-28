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
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak target] in
            guard let target = target else { return }
            self.attachOfflineActionButton(to: target)
        }
    }

    private func attachOfflineActionButton(to vc: UIViewController) {
        // Find labels in header to extract Title and Artist
        var foundLabels: [UILabel] = []
        
        func collectLabels(in view: UIView) {
            if let label = view as? UILabel, let text = label.text, !text.isEmpty {
                foundLabels.append(label)
            }
            for sub in view.subviews {
                collectLabels(in: sub)
            }
        }
        
        collectLabels(in: vc.view)
        guard foundLabels.count >= 1 else { return }
        
        let title = foundLabels[0].text ?? ""
        let artist = foundLabels.count > 1 ? (foundLabels[1].text ?? "") : ""
        guard !title.isEmpty, title != "Not playing" else { return }
        
        // Find UITableView
        func findTableView(in view: UIView) -> UITableView? {
            if let tv = view as? UITableView { return tv }
            for sub in view.subviews {
                if let found = findTableView(in: sub) { return found }
            }
            return nil
        }
        
        guard let tableView = findTableView(in: vc.view) else { return }
        
        let buttonTag = 948271
        if tableView.viewWithTag(buttonTag) != nil { return }
        
        // Deterministic track identifier for this context menu item
        let trackKey = "\(artist)_\(title)".replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
        let isDownloaded = EeveeOfflineStorageManager.shared.isTrackDownloaded(trackId: trackKey)
            || (capturedTrackId.map { EeveeOfflineStorageManager.shared.isTrackDownloaded(trackId: $0) } ?? false)
        
        // Native Spotify-styled Action Button Row
        let rowButton = UIButton(type: .custom)
        rowButton.tag = buttonTag
        rowButton.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        rowButton.layer.cornerRadius = 8
        rowButton.clipsToBounds = true
        rowButton.contentHorizontalAlignment = .left
        
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        let iconName = isDownloaded ? "trash.fill" : "arrow.down.circle.fill"
        let icon = UIImage(systemName: iconName, withConfiguration: iconConfig)
        rowButton.setImage(icon, for: .normal)
        rowButton.tintColor = isDownloaded ? .systemRed : UIColor(red: 0.12, green: 0.84, blue: 0.38, alpha: 1.0)
        
        let buttonTitle = isDownloaded ? "  Удалить из офлайна" : "  Скачать в офлайн"
        rowButton.setTitle(buttonTitle, for: .normal)
        rowButton.setTitleColor(.white, for: .normal)
        rowButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        rowButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        
        // Create or update tableHeaderView cleanly
        let originalHeader = tableView.tableHeaderView
        let newHeaderContainer = UIView()
        
        if let original = originalHeader {
            original.translatesAutoresizingMaskIntoConstraints = false
            newHeaderContainer.addSubview(original)
            
            rowButton.translatesAutoresizingMaskIntoConstraints = false
            newHeaderContainer.addSubview(rowButton)
            
            NSLayoutConstraint.activate([
                original.topAnchor.constraint(equalTo: newHeaderContainer.topAnchor),
                original.leadingAnchor.constraint(equalTo: newHeaderContainer.leadingAnchor),
                original.trailingAnchor.constraint(equalTo: newHeaderContainer.trailingAnchor),
                
                rowButton.topAnchor.constraint(equalTo: original.bottomAnchor, constant: 8),
                rowButton.leadingAnchor.constraint(equalTo: newHeaderContainer.leadingAnchor, constant: 16),
                rowButton.trailingAnchor.constraint(equalTo: newHeaderContainer.trailingAnchor, constant: -16),
                rowButton.heightAnchor.constraint(equalToConstant: 44),
                rowButton.bottomAnchor.constraint(equalTo: newHeaderContainer.bottomAnchor, constant: -8)
            ])
            
            newHeaderContainer.frame = CGRect(
                x: 0,
                y: 0,
                width: tableView.bounds.width,
                height: original.frame.height + 60
            )
        } else {
            rowButton.frame = CGRect(x: 16, y: 8, width: tableView.bounds.width - 32, height: 44)
            newHeaderContainer.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 60)
            newHeaderContainer.addSubview(rowButton)
        }
        
        tableView.tableHeaderView = newHeaderContainer
        
        // Action Handler
        rowButton.addAction(UIAction { [weak vc] _ in
            if isDownloaded {
                EeveeOfflineStorageManager.shared.deleteTrack(trackId: trackKey)
                if let cid = capturedTrackId {
                    EeveeOfflineStorageManager.shared.deleteTrack(trackId: cid)
                }
                SponsorBlockToast.shared.show("✓ Удалено из офлайна: \(title)")
            } else {
                EeveeOfflineStorageManager.shared.isAutoCacheEnabled = true
                let targetURL = EeveeOfflineStorageManager.shared.activeStorageURL.appendingPathComponent("temp_\(trackKey).m4a")
                EeveeStartAudioRecording(targetURL.path)
                SponsorBlockToast.shared.show(" Идет запись полного аудиопотока в офлайн...")
            }
            vc?.dismiss(animated: true)
        }, for: .touchUpInside)
    }
}
