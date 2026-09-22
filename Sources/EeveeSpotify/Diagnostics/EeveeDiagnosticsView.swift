import SwiftUI
import UIKit

struct EeveeDiagnosticsView: View {
    @State private var reportCopied = false
    @State private var logCleared = false

    var body: some View {
        List {
            Section(header: Text("System & Version")) {
                HStack {
                    Text("Spotify Version")
                    Spacer()
                    Text(EeveeDiagnosticsManager.shared.spotifyVersion)
                        .foregroundColor(.gray)
                }
                HStack {
                    Text("Eevee Version")
                    Spacer()
                    Text(EeveeDiagnosticsManager.shared.eeveeVersion)
                        .foregroundColor(.gray)
                }
                HStack {
                    Text("Device & OS")
                    Spacer()
                    Text(EeveeDiagnosticsManager.shared.systemInfo)
                        .foregroundColor(.gray)
                }
                HStack {
                    Text("Active Patch")
                    Spacer()
                    Text(EeveeDiagnosticsManager.shared.patchTypeDescription)
                        .foregroundColor(.gray)
                }
                HStack {
                    Text("Overwrite Config")
                    Spacer()
                    Text(UserDefaults.overwriteConfiguration ? "Enabled" : "Disabled")
                        .foregroundColor(UserDefaults.overwriteConfiguration ? .green : .gray)
                }
            }

            Section(header: Text("Current Playback")) {
                HStack {
                    Text("Track")
                    Spacer()
                    Text(EeveeDiagnosticsManager.shared.currentTrackTitle)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
                HStack {
                    Text("Artist")
                    Spacer()
                    Text(EeveeDiagnosticsManager.shared.currentArtist)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
                HStack {
                    Text("State")
                    Spacer()
                    Text(EeveeDiagnosticsManager.shared.playbackState)
                        .foregroundColor(.gray)
                }
                HStack {
                    Text("Position")
                    Spacer()
                    Text(EeveeDiagnosticsManager.shared.playbackPosition)
                        .foregroundColor(.gray)
                }
            }

            Section(header: Text("Lyrics Status"), footer: Text("Shows which provider was requested and which one actually delivered lyrics.")) {
                HStack {
                    Text("Configured Source")
                    Spacer()
                    Text(UserDefaults.lyricsSource.description)
                        .foregroundColor(.gray)
                }
                HStack {
                    Text("Last Provider")
                    Spacer()
                    Text(EeveeDiagnosticsManager.shared.lastLyricsProvider)
                        .foregroundColor(.gray)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last Fetch Result")
                        .font(.subheadline)
                    Text(EeveeDiagnosticsManager.shared.lastLyricsStatus)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .padding(.vertical, 2)
            }

            Section(header: Text("Actions")) {
                Button {
                    let report = EeveeDiagnosticsManager.shared.buildFullReport()
                    UIPasteboard.general.string = report
                    PopUpHelper.showPopUp(
                        message: "Diagnostic report & logs copied to clipboard!",
                        buttonText: "OK".uiKitLocalized
                    )
                } label: {
                    HStack {
                        Image(systemName: "doc.on.doc")
                            .foregroundColor(.blue)
                        Text("Copy Report to Clipboard")
                    }
                }

                Button {
                    let logPath = NSTemporaryDirectory() + "eeveespotify_debug.log"
                    guard FileManager.default.fileExists(atPath: logPath),
                          let logData = FileManager.default.contents(atPath: logPath),
                          logData.count > 0 else {
                        PopUpHelper.showPopUp(message: "no_debug_log_found".localized, buttonText: "no_debug_log_found_ok".localized)
                        return
                    }
                    let logURL = URL(fileURLWithPath: logPath)
                    let activityVC = UIActivityViewController(activityItems: [logURL], applicationActivities: nil)
                    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let rootVC = scene.windows.first?.rootViewController {
                        var topVC = rootVC
                        while let presented = topVC.presentedViewController { topVC = presented }
                        if let popover = activityVC.popoverPresentationController {
                            popover.sourceView = topVC.view
                            popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
                        }
                        topVC.present(activityVC, animated: true)
                    }
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(.blue)
                        Text("Export Full Debug Log")
                    }
                }

                Button {
                    let logPath = NSTemporaryDirectory() + "eeveespotify_debug.log"
                    try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
                    writeDebugLog("Log cleared by user")
                    PopUpHelper.showPopUp(message: "debug_log_cleared".localized, buttonText: "debug_log_cleared_ok".localized)
                } label: {
                    HStack {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                        Text("Clear Debug Log")
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .listStyle(GroupedListStyle())
    }
}
