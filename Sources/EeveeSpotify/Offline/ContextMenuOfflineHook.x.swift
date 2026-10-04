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
            self.attachOfflineRow(to: target)
        }
    }

    private func attachOfflineRow(to vc: UIViewController) {
        // Collect labels from the header to get track title and artist
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
        
        let rowTag = 948271
        if tableView.viewWithTag(rowTag) != nil { return }
        
        let trackKey = "\(artist)_\(title)".replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
        let isDownloaded = EeveeOfflineStorageManager.shared.isTrackDownloaded(trackId: trackKey)
            || (capturedTrackId.map { EeveeOfflineStorageManager.shared.isTrackDownloaded(trackId: $0) } ?? false)
        
        // Build a native-styled Spotify Action Row
        let rowContainer = UIButton(type: .custom)
        rowContainer.tag = rowTag
        rowContainer.backgroundColor = .clear
        rowContainer.contentHorizontalAlignment = .left
        
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        let iconName = isDownloaded ? "trash" : "arrow.down.circle"
        let icon = UIImage(systemName: iconName, withConfiguration: iconConfig)
        
        rowContainer.setImage(icon, for: .normal)
        rowContainer.tintColor = isDownloaded ? UIColor.systemRed : UIColor.white
        
        let titleString = isDownloaded ? "   Удалить из офлайна" : "   Скачать в офлайн"
        rowContainer.setTitle(titleString, for: .normal)
        rowContainer.setTitleColor(.white, for: .normal)
        rowContainer.setTitleColor(UIColor.white.withAlphaComponent(0.6), for: .highlighted)
        rowContainer.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .regular)
        rowContainer.contentEdgeInsets = UIEdgeInsets(top: 0, left: 24, bottom: 0, right: 24)
        
        // Combine seamlessly with table header
        let originalHeader = tableView.tableHeaderView
        let newHeader = UIView()
        let rowHeight: CGFloat = 52
        
        if let original = originalHeader {
            let origHeight = original.frame.height
            newHeader.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: origHeight + rowHeight)
            original.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: origHeight)
            newHeader.addSubview(original)
            
            rowContainer.frame = CGRect(x: 0, y: origHeight, width: tableView.bounds.width, height: rowHeight)
            newHeader.addSubview(rowContainer)
        } else {
            newHeader.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: rowHeight)
            rowContainer.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: rowHeight)
            newHeader.addSubview(rowContainer)
        }
        
        tableView.tableHeaderView = newHeader
        
        // Action Handler
        rowContainer.addAction(UIAction { [weak vc] _ in
            if isDownloaded {
                EeveeOfflineStorageManager.shared.deleteTrack(trackId: trackKey)
                if let cid = capturedTrackId {
                    EeveeOfflineStorageManager.shared.deleteTrack(trackId: cid)
                }
                SponsorBlockToast.shared.show("✓ Удалено из офлайна: \(title)")
            } else {
                EeveeOfflineCoordinator.shared.startManualDownload(
                    trackId: capturedTrackId ?? trackKey,
                    title: title,
                    artist: artist
                )
            }
            vc?.dismiss(animated: true)
        }, for: .touchUpInside)
    }
}
