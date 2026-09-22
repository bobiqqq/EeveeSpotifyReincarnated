import Foundation

class GeniusLyricsRepository: LyricsRepository {
    static let shared = GeniusLyricsRepository()
    private let jsonDecoder: JSONDecoder
    private let apiUrl = "https://api.genius.com"
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "X-Genius-iOS-Version": "6.21.0",
            "X-Genius-Logged-Out": "true",
            "User-Agent": "Genius/1109 \(URLSessionHelper.CFNetworkVersion) \(URLSessionHelper.DarwinVersion)"
        ]
        
        session = URLSession(configuration: configuration)
        
        jsonDecoder = JSONDecoder()
        jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
    }
    
    private func perform(
        _ path: String, 
        query: [String:Any] = [:]
    ) throws -> GeniusDataResponse? {
        var stringUrl = "\(apiUrl)\(path)"

        if !query.isEmpty {
            let queryString = query.queryString
            stringUrl += "?\(queryString)"
        }
        
        let request = URLRequest(url: URL(string: stringUrl)!, timeoutInterval: 6.0)

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var error: Error?

        let task = session.dataTask(with: request) { response, _, err in
            error = err
            data = response
            semaphore.signal()
        }

        task.resume()
        semaphore.wait()

        if let error = error {
            throw error
        }

        guard let data,
              let rootResponse = try? jsonDecoder.decode(GeniusRootResponse.self, from: data) else {
            throw LyricsError.decodingError
        }
        return rootResponse.response
    }
    
    
    private func searchSong(_ query: String) throws -> [GeniusHit] {
        let data = try perform("/search/song", query: ["q": query])
        
        guard
            case .sections(let sectionsResponse) = data,
            let section = sectionsResponse.sections.first
        else {
            throw LyricsError.decodingError
        }
        
        return section.hits
    }

    private func getSongInfo(_ songId: Int) throws -> GeniusSong {
        let data = try perform("/songs/\(songId)", query: ["text_format": "plain"])
        
        guard case .song(let songResponse) = data else {
            throw LyricsError.decodingError
        }
        
        return songResponse.song
    }
    
    
    private func cleanTrackTitle(_ title: String) -> String {
        var s = title
        // Remove feat / ft / with parenthetical expressions: (feat. X), [feat X], (with Y)
        s = s.removeMatches("(?i)\\s*[\\[\\(](?:feat\\.?|ft\\.?|with|featuring)[^\\]\\)]*[\\]\\)]")
        // Remove remaster / bonus / deluxe / live tags
        s = s.removeMatches("(?i)\\s*[\\[\\(](?:.*remaster.*|.*deluxe.*|.*edition.*|.*version.*|.*edit.*|.*live.*|.*bonus.*|.*mix.*|.*acoustic.*|.*explicit.*|.*single.*|.*soundtrack.*|.*stereo.*|.*mono.*|.*audio.*)[\\]\\)]")
        // Remove trailing dash expressions: " - Remastered", " - Live at ...", " - Radio Edit"
        s = s.removeMatches("(?i)\\s*-\\s*(?:remaster.*|deluxe.*|live.*|bonus.*|radio edit.*|edit|single version.*|acoustic.*|soundtrack.*)")
        // Remove leftover brackets and quotes
        s = s.removeMatches("[\\[\\]\"]")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanArtistName(_ artist: String) -> String {
        var a = artist
        a = a.removeMatches("(?i)\\s*(?:feat\\.?|ft\\.?|,|&|/|x|with).*")
        return a.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mostRelevantHitResult(
        hits: [GeniusHit],
        cleanTitle: String,
        primaryArtist: String,
        romanized: Bool,
        hasFoundRomanizedLyrics: inout Bool
    ) -> GeniusHitResult {
        let results = hits.map { $0.result }

        let matchingByTitle = results.filter {
            $0.title.containsInsensitive(cleanTitle) || cleanTitle.containsInsensitive($0.title)
        }

        let cleanArtist = cleanArtistName(primaryArtist)
        let matchingByBoth = matchingByTitle.filter {
            $0.artistNames.containsInsensitive(cleanArtist)
                || $0.artistNames.containsInsensitive(primaryArtist)
        }

        // Best match: title+artist → title only → first result
        let pool = !matchingByBoth.isEmpty ? matchingByBoth
                 : !matchingByTitle.isEmpty ? matchingByTitle
                 : results

        if romanized, let romanizedSong = pool.first(
            where: { $0.artistNames == "Genius Romanizations" }
        ) {
            hasFoundRomanizedLyrics = true
            return romanizedSong
        }

        return pool.first!
    }
    
    private func mapLyricsLines(_ rawLines: [String]) -> [String] {
        var lines = rawLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
        
        lines.removeAll { $0 ~= "\\[.*\\]" }

        lines = Array(
            lines
                .drop(while: { $0.isEmpty })
                .dropLast(while: { $0.isEmpty })
        )
        
        return lines
    }
    
    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let cleanTitle = cleanTrackTitle(query.title)
        let cleanArtist = cleanArtistName(query.primaryArtist)

        var hits: [GeniusHit] = []

        // 1. Attempt with clean title + clean artist
        if !cleanTitle.isEmpty && !cleanArtist.isEmpty {
            hits = (try? searchSong("\(cleanTitle) \(cleanArtist)")) ?? []
        }

        // 2. Attempt with basic stripped title + primary artist
        if hits.isEmpty {
            let stripped = query.title.strippedTrackTitle
            hits = (try? searchSong("\(stripped) \(query.primaryArtist)")) ?? []
        }

        // 3. Fallback: Search with clean title only
        if hits.isEmpty && !cleanTitle.isEmpty {
            hits = (try? searchSong(cleanTitle)) ?? []
        }

        guard !hits.isEmpty else {
            throw LyricsError.noSuchSong
        }
        
        var hasFoundRomanizedLyrics = false
        
        let song = mostRelevantHitResult(
            hits: hits,
            cleanTitle: cleanTitle.isEmpty ? query.title : cleanTitle,
            primaryArtist: query.primaryArtist,
            romanized: options.romanization,
            hasFoundRomanizedLyrics: &hasFoundRomanizedLyrics
        )
        
        let songInfo = try getSongInfo(song.id)
        let plainLines = songInfo.lyrics.plain.components(separatedBy: "\n")
        
        var romanization = LyricsRomanizationStatus.original
        
        if hasFoundRomanizedLyrics {
            romanization = .romanized
        }
        else if songInfo.language.isCanBeRomanizedLanguage {
            romanization = .canBeRomanized
        }
    
        return LyricsDto(
            lines: mapLyricsLines(plainLines).map { line in LyricsLineDto(content: line) },
            timeSynced: false,
            romanization: romanization
        )
    }
}
