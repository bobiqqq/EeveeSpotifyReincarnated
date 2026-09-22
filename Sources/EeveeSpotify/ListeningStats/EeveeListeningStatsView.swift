import SwiftUI
import UIKit

struct EeveeListeningStatsView: View {
    @State private var selectedDays: Int = 30
    @State private var topTracks: [(title: String, artist: String, plays: Int, totalDuration: Double)] = []
    @State private var topArtists: [(artist: String, plays: Int, totalDuration: Double)] = []
    @State private var totalListeningTime: Double = 0
    @State private var totalPlays: Int = 0

    private func refresh() {
        topTracks = EeveeListeningStatsManager.shared.getTopTracks(days: selectedDays)
        topArtists = EeveeListeningStatsManager.shared.getTopArtists(days: selectedDays)
        totalListeningTime = EeveeListeningStatsManager.shared.getTotalListeningTime(days: selectedDays)
        totalPlays = EeveeListeningStatsManager.shared.getTotalPlaysCount(days: selectedDays)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours) h \(minutes) min"
        } else {
            return "\(minutes) min"
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Период", selection: $selectedDays) {
                    Text("7 дней").tag(7)
                    Text("30 дней").tag(30)
                    Text("60 дней (2 мес.)").tag(60)
                }
                .pickerStyle(SegmentedPickerStyle())
                .onChange(of: selectedDays) { _ in
                    refresh()
                }
            }

            Section(header: Text("Общая статистика")) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Время музыки")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text(formatDuration(totalListeningTime))
                            .font(.headline)
                            .foregroundColor(.green)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Всего треков")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text("\(totalPlays)")
                            .font(.headline)
                            .foregroundColor(.primary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section(header: Text("Топ Артистов")) {
                if topArtists.isEmpty {
                    Text("Пока нет данных о прослушиваниях (трек засчитывается после 30 сек.)")
                        .font(.footnote)
                        .foregroundColor(.gray)
                } else {
                    ForEach(Array(topArtists.prefix(10).enumerated()), id: \.offset) { index, item in
                        HStack {
                            Text("\(index + 1)")
                                .font(.headline)
                                .foregroundColor(.gray)
                                .frame(width: 24, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.artist)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text(formatDuration(item.totalDuration))
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Text("\(item.plays) \(item.plays == 1 ? "прослуш." : "прослуш.")")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section(header: Text("Топ Треков")) {
                if topTracks.isEmpty {
                    Text("Пока нет данных о прослушиваниях")
                        .font(.footnote)
                        .foregroundColor(.gray)
                } else {
                    ForEach(Array(topTracks.prefix(15).enumerated()), id: \.offset) { index, item in
                        HStack {
                            Text("\(index + 1)")
                                .font(.headline)
                                .foregroundColor(.gray)
                                .frame(width: 24, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Text(item.artist)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("\(item.plays)")
                                .font(.subheadline)
                                .foregroundColor(.green)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section(header: Text("Управление данными"), footer: Text("Статистика хранится локально на устройстве со скользящим окном 60 дней.")) {
                Button {
                    EeveeListeningStatsManager.shared.clearAll()
                    refresh()
                    PopUpHelper.showPopUp(message: "Статистика прослушиваний сброшена.", buttonText: "OK".uiKitLocalized)
                } label: {
                    HStack {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                        Text("Сбросить статистику")
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .listStyle(GroupedListStyle())
        .onAppear {
            refresh()
        }
    }
}
