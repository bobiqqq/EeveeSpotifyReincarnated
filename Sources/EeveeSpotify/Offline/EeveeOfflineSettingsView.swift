import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct EeveeOfflineSettingsView: View {
    @State private var autoCache = EeveeOfflineStorageManager.shared.isAutoCacheEnabled
    @State private var isShowingPicker = false
    @State private var tracks: [OfflineTrackInfo] = []
    @State private var totalSize: Int64 = 0

    private func refresh() {
        tracks = EeveeOfflineStorageManager.shared.allTracks()
        totalSize = EeveeOfflineStorageManager.shared.totalStorageSize
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    var body: some View {
        List {
            Section(
                header: Text("Параметры офлайна"),
                footer: Text("При включении треки автоматически сохраняются в высоком качестве во время прослушивания. Они сразу доступны без интернета в разделе «Локальные файлы».")
            ) {
                Toggle("Авто-сохранение треков", isOn: $autoCache)
                    .onChange(of: autoCache) { val in
                        EeveeOfflineStorageManager.shared.isAutoCacheEnabled = val
                    }
            }

            Section(
                header: Text("Место хранения"),
                footer: Text("Если выбрать постоянную папку в приложении «Файлы» (на iPhone или в iCloud), скачанная музыка сохранится даже при удалении и переустановке приложения.")
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(EeveeOfflineStorageManager.shared.isUsingCustomExternalFolder ? "Внешняя папка (в «Файлах»)" : "Внутренняя папка Spotify")
                        .font(.subheadline)
                    Text(EeveeOfflineStorageManager.shared.activeStorageURL.path)
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)

                Button {
                    isShowingPicker = true
                } label: {
                    HStack {
                        Image(systemName: "folder.badge.gearshape")
                            .foregroundColor(.blue)
                        Text("Выбрать внешнюю папку в «Файлах»")
                    }
                }

                if EeveeOfflineStorageManager.shared.isUsingCustomExternalFolder {
                    Button {
                        EeveeOfflineStorageManager.shared.resetToDefaultFolder()
                        refresh()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.uturn.backward")
                                .foregroundColor(.orange)
                            Text("Вернуть стандартную папку")
                                .foregroundColor(.orange)
                        }
                    }
                }
            }

            Section(header: Text("Скачанная музыка")) {
                HStack {
                    Text("Всего сохранено")
                    Spacer()
                    Text("\(tracks.count) треков (\(formatBytes(totalSize)))")
                        .foregroundColor(.gray)
                }

                if tracks.isEmpty {
                    Text("Пока нет сохранённых треков. Включите любой трек — он автоматически сохранится в офлайн.")
                        .font(.footnote)
                        .foregroundColor(.gray)
                } else {
                    ForEach(tracks) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Text("\(item.artist) • \(formatDuration(item.durationSeconds))")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                EeveeOfflineStorageManager.shared.deleteTrack(trackId: item.trackId)
                                refresh()
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red.opacity(0.8))
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                        .padding(.vertical, 2)
                    }

                    Button {
                        EeveeOfflineStorageManager.shared.deleteAllTracks()
                        refresh()
                    } label: {
                        HStack {
                            Image(systemName: "trash.fill")
                                .foregroundColor(.red)
                            Text("Очистить все скачанные треки")
                                .foregroundColor(.red)
                        }
                    }
                }
            }
        }
        .listStyle(GroupedListStyle())
        .onAppear {
            refresh()
        }
        .sheet(isPresented: $isShowingPicker) {
            FolderPickerViewControllerRepresentable { selectedURL in
                EeveeOfflineStorageManager.shared.setCustomFolder(url: selectedURL)
                refresh()
            }
        }
    }
}

// MARK: - UIDocumentPickerViewController Bridge

private struct FolderPickerViewControllerRepresentable: UIViewControllerRepresentable {
    let onFolderPicked: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFolderPicked: onFolderPicked)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFolderPicked: (URL) -> Void

        init(onFolderPicked: @escaping (URL) -> Void) {
            self.onFolderPicked = onFolderPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onFolderPicked(url)
        }
    }
}
