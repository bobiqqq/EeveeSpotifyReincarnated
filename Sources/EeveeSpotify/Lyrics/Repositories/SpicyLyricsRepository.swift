import Foundation

// MARK: - SpicyLyricsRepository
//
// Fetches lyrics from api.spicylyrics.org and converts the response into LyricsDto.
//
// ── Token availability ───────────────────────────────────────────────────────
// spotifyAccessToken is captured lazily from Spotify's outgoing requests.
// On first track load it may be nil. The Spicetify extension uses
// Platform.GetSpotifyAccessToken() which awaits the token asynchronously.
// We replicate that by polling spotifyAccessToken for up to 5 seconds before
// giving up — this prevents an immediate 401 from the API triggering Genius fallback.
//
// ── iOS 27 crash ─────────────────────────────────────────────────────────────
// The EXC_BREAKPOINT / _swift_task_checkIsolatedSwift crash is fixed in
// DataLoaderServiceHooks.x.swift by dispatching orig.URLSession callbacks
// onto the main queue. No changes needed here for that.

class SpicyLyricsRepository: LyricsRepository {

    static let shared = SpicyLyricsRepository()
    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest  = 3.5
        config.timeoutIntervalForResource = 4.0
        config.allowsExpensiveNetworkAccess   = true
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    private let session: URLSession

    private static let apiUrl        = "https://api.spicylyrics.org"
    private static let authHeaderKey = "SpicyLyrics-WebAuth"
    private static let clientVersion = "6.4.10"

    // MARK: - Token wait
    //
    // Poll for spotifyAccessToken up to `timeout` seconds.
    // Returns the token or nil if not available in time.
    private func waitForToken(timeout: TimeInterval = 1.5) -> String? {
        if let token = spotifyAccessToken { return token }

        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            if let token = spotifyAccessToken { return token }
        }
        return nil
    }

    // MARK: - Network

    private func performQuery(trackId: String) throws -> Data {
        let personalKey = UserDefaults.spicyLyricsKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !personalKey.isEmpty {
            do {
                writeDebugLog("[SpicyLyrics] Using personal API key for \(trackId)")
                return try performV1Request(trackId: trackId, key: personalKey)
            } catch {
                writeDebugLog("[SpicyLyrics] v1 request failed with personal key (\(error)), trying query")
            }
        }

        let (data, httpStatus) = try performQueryOnce(trackId: trackId)
        if httpStatus == 503 {
            writeDebugLog("[SpicyLyrics] Track \(trackId) is queued (503) — falling back to next provider")
            throw LyricsError.noSuchSong
        }
        return data
    }

    private func performV1Request(trackId: String, key: String) throws -> Data {
        guard let url = URL(string: "\(SpicyLyricsRepository.apiUrl)/v1/lyrics/\(trackId)") else {
            throw LyricsError.decodingError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("SpicyLyrics-iOS/\(SpicyLyricsRepository.clientVersion)", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?
        var statusCode = 0

        session.dataTask(with: request) { data, response, error in
            responseData = data
            responseError = error
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            semaphore.signal()
        }.resume()

        semaphore.wait()

        if let error = responseError { throw error }
        if statusCode == 404 { throw LyricsError.noSuchSong }
        guard statusCode == 200, let data = responseData else {
            writeDebugLog("[SpicyLyrics] v1 returned HTTP \(statusCode)")
            throw LyricsError.decodingError
        }

        return data
    }

    /// Single request attempt. Returns the raw envelope bytes alongside the
    /// query's own httpStatus (peeked out of the envelope here, ahead of
    /// parseLyricsData's own real parse of it) purely so performQuery can
    /// decide whether to retry — parseLyricsData still does the real
    /// envelope parsing and status handling on whichever attempt succeeds.
    private func performQueryOnce(trackId: String) throws -> (Data, Int) {
        let data = try performRequest(trackId: trackId)
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let queriesRaw = json["queries"] as? [[String: Any]],
            let matchedQuery = queriesRaw.first(where: { $0["operationId"] as? String == "0" }),
            let result = matchedQuery["result"] as? [String: Any]
        else {
            // Malformed envelope — let parseLyricsData handle (and log) this
            // properly rather than duplicating that error path here.
            return (data, 0)
        }
        let httpStatus = result["httpStatus"] as? Int ?? 0
        return (data, httpStatus)
    }

    private func performRequest(trackId: String) throws -> Data {
        guard let url = URL(string: "\(SpicyLyricsRepository.apiUrl)/query") else {
            throw LyricsError.decodingError
        }

        let body: [String: Any] = [
            "queries": [
                [
                    "operation": "lyrics",
                    "variables": [
                        "id":   trackId,
                        "auth": SpicyLyricsRepository.authHeaderKey
                    ]
                ]
            ],
            "client": ["version": SpicyLyricsRepository.clientVersion]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json",                   forHTTPHeaderField: "Content-Type")
        request.setValue(SpicyLyricsRepository.clientVersion, forHTTPHeaderField: "SpicyLyrics-Version")
        // Confirmed against the real client's Query.ts: every request sends
        // this alongside SpicyLyrics-Version, unconditionally, with no
        // branching logic elsewhere in that file — it isn't a device/UA
        // signal, it's a flat request flag. This was missing here entirely,
        // which is the actual explanation for the Static/Line-vs-Syllable
        // discrepancy the sec-ch-ua/Client-Hints headers below were guessed
        // at fixing and didn't: the server was very possibly falling back to
        // a lower-fidelity response format without it.
        request.setValue("2", forHTTPHeaderField: "X-mode")

        // Spoofed browser identity headers (Origin/Referer/User-Agent/Client
        // Hints/Sec-Fetch), captured via mitmproxy from a real desktop
        // session. These aren't things the extension's own JS sets — inside
        // Spotify's actual Chromium runtime the browser sets them
        // automatically from the page context — so a native URLSession
        // needs to fake them to look like that same environment. Confirmed
        // via the real client's Query.ts that they play no role in the
        // Static/Line-vs-Syllable discrepancy specifically (that was
        // X-mode, above); kept here for general request realism.
        request.setValue("https://xpui.app.spotify.com",  forHTTPHeaderField: "Origin")
        request.setValue("https://xpui.app.spotify.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.7680.179 Spotify/1.2.92.148 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("\"Windows\"",                      forHTTPHeaderField: "sec-ch-ua-platform")
        request.setValue("\"Not-A.Brand\";v=\"24\", \"Chromium\";v=\"146\"", forHTTPHeaderField: "sec-ch-ua")
        request.setValue("?0",                                forHTTPHeaderField: "sec-ch-ua-mobile")
        request.setValue("*/*",                               forHTTPHeaderField: "Accept")
        request.setValue("cross-site",                        forHTTPHeaderField: "sec-fetch-site")
        request.setValue("cors",                              forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("empty",                             forHTTPHeaderField: "sec-fetch-dest")
        request.setValue("gzip, deflate, br, zstd",           forHTTPHeaderField: "Accept-Encoding")
        request.setValue("en-Latn-US,en-US;q=0.9,en-Latn;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue("u=1, i",                            forHTTPHeaderField: "priority")

        // Wait for the Spotify Bearer token — mirrors Platform.GetSpotifyAccessToken()
        // in the Spicetify extension. Without a valid token the API returns non-200
        // immediately, which falsely triggers Genius fallback.
        if let token = waitForToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: SpicyLyricsRepository.authHeaderKey)
            writeDebugLog("[SpicyLyrics] Using captured token for \(trackId)")
        } else {
            writeDebugLog("[SpicyLyrics] No token available for \(trackId) — proceeding unauthenticated")
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?

        session.dataTask(with: request) { data, _, error in
            responseData = data
            responseError = error
            semaphore.signal()
        }.resume()

        semaphore.wait()

        if let error = responseError {
            writeDebugLog("[SpicyLyrics] Network error for \(trackId): \(error)")
            throw error
        }
        guard let data = responseData else {
            writeDebugLog("[SpicyLyrics] No data for \(trackId)")
            throw LyricsError.decodingError
        }
        writeDebugLog("[SpicyLyrics] Received \(data.count) bytes for track \(trackId)")
        return data
    }

    // MARK: - Parse

    private func parseLyricsData(_ data: Data, trackId: String, query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        // 1. Direct v1 API response check (when using personal API key)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = json["Status"] as? Int,
           let body = json["Body"] as? [String: Any] {
            if status == 404 { throw LyricsError.noSuchSong }
            guard status == 200 else {
                writeDebugLog("[SpicyLyrics] v1 error status: \(status)")
                throw LyricsError.noSuchSong
            }
            let packed = SLObjPackValue.fromAny(body)
            guard let type = packed["Type"]?.stringValue else { throw LyricsError.decodingError }
            writeDebugLog("[SpicyLyrics] v1 lyrics type=\(type) for \(trackId)")
            switch type {
            case "Syllable": return parseSyllableLyrics(packed, trackId: trackId, query: query, options: options)
            case "Line":     return parseLineLyrics(packed)
            case "Static":   return parseStaticLyrics(packed)
            default:         throw LyricsError.decodingError
            }
        }

        // 2. /query envelope response check (via captured Spotify token)
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let queriesRaw = json["queries"] as? [[String: Any]]
        else {
            let rawBody = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            writeDebugLog("[SpicyLyrics] Malformed envelope for \(trackId): \(rawBody)")
            throw LyricsError.decodingError
        }

        guard
            let matchedQuery = queriesRaw.first(where: { $0["operationId"] as? String == "0" }),
            let result = matchedQuery["result"] as? [String: Any]
        else {
            let rawBody = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            writeDebugLog("[SpicyLyrics] No matching operationId 0 for \(trackId): \(rawBody)")
            throw LyricsError.decodingError
        }

        let httpStatus = result["httpStatus"] as? Int ?? 0
        writeDebugLog("[SpicyLyrics] API status \(httpStatus) for \(trackId)")

        switch httpStatus {
        case 404:
            throw LyricsError.noSuchSong
        case 200:
            break
        case 401, 403:
            let errorDetail = String(describing: result["data"] ?? "")
            writeDebugLog("[SpicyLyrics] Auth error \(httpStatus) for \(trackId): \(errorDetail) — clearing cached token")
            spotifyAccessToken = nil
            throw LyricsError.noSuchSong
        default:
            writeDebugLog("[SpicyLyrics] Unexpected status \(httpStatus) for \(trackId)")
            throw LyricsError.noSuchSong
        }

        guard let rawData = result["data"] else { throw LyricsError.decodingError }

        let packed: SLObjPackValue
        do {
            packed = try SLObjPack.unpack(rawData)
        } catch {
            writeDebugLog("[SpicyLyrics] SLObjPack error for \(trackId): \(error)")
            throw LyricsError.decodingError
        }

        guard let type = packed["Type"]?.stringValue else {
            writeDebugLog("[SpicyLyrics] Missing Type for \(trackId)")
            throw LyricsError.decodingError
        }

        writeDebugLog("[SpicyLyrics] Lyrics type=\(type) for \(trackId)")

        switch type {
        case "Syllable": return parseSyllableLyrics(packed, trackId: trackId, query: query, options: options)
        case "Line":     return parseLineLyrics(packed)
        case "Static":   return parseStaticLyrics(packed)
        default:
            writeDebugLog("[SpicyLyrics] Unknown type '\(type)' for \(trackId)")
            throw LyricsError.decodingError
        }
    }

    // MARK: Syllable lyrics

    private func parseSyllableLyrics(_ root: SLObjPackValue, trackId: String, query: LyricsSearchQuery, options: LyricsOptions) -> LyricsDto {
        guard let content = root["Content"]?.arrayValue else { return emptyDto() }

        var lines        = [LyricsLineDto]()
        var karaokeLines = [KaraokeLineDto]()
        var hasRomanized = root["HasTransliterations"]?.boolValue ?? false

        for entry in content {
            guard entry["Type"]?.stringValue == "Vocal",
                  let lead = entry["Lead"] else { continue }

            let lineText: String
            var karaokeSyllables = [KaraokeSyllableDto]()

            if let syllables = lead["Syllables"]?.arrayValue, !syllables.isEmpty {
                // Real client rule (Syllable.ts / tools.ts): IsPartOfWord is a
                // FORWARD-looking flag — a syllable with IsPartOfWord=true means
                // the word continues into the *next* syllable with no gap (e.g.
                // "Lo" (IsPartOfWord=true) + "la" -> "Lola"). So whether a space
                // goes before the *current* syllable depends on the *previous*
                // syllable's flag, not this one's own. (Verified directly against
                // the real client: Syllable.ts's word-grouping gates inclusion on
                // `lead.IsPartOfWord || (prev?.IsPartOfWord && currentWordGroup)`,
                // and tools.ts's convertSyllableToStatic appends a space *after*
                // a syllable only `if (!syllable.IsPartOfWord)`.) Reading this
                // backwards (checking the current syllable's own flag to decide
                // the preceding space, as an earlier version of this file did)
                // is what produced broken spacing like "wasLo la" instead of
                // "was Lola" — plain .joined() (no separator) had the same
                // underlying problem, producing "Doyourecall,notlongago?".
                var text = ""
                var previousIsPartOfWord = false
                for syllable in syllables {
                    guard let syllableText = syllable["Text"]?.stringValue else { continue }
                    let isPartOfWord = syllable["IsPartOfWord"]?.boolValue ?? false
                    if !text.isEmpty && !previousIsPartOfWord {
                        text += " "
                    }
                    text += syllableText
                    previousIsPartOfWord = isPartOfWord

                    let startMs = syllable["StartTime"]?.doubleValue.map { Int($0 * 1000) } ?? 0
                    let endMs   = syllable["EndTime"]?.doubleValue.map { Int($0 * 1000) } ?? startMs
                    karaokeSyllables.append(KaraokeSyllableDto(
                        text: syllableText,
                        startMs: startMs,
                        endMs: endMs,
                        isPartOfWord: isPartOfWord
                    ))
                }
                lineText = text
                if syllables.contains(where: { ($0["TransliteratedText"]?.stringValue ?? "").isEmpty == false }) {
                    hasRomanized = true
                }
            } else if let text = lead["Text"]?.stringValue {
                lineText = text
            } else {
                continue
            }

            if (lead["TransliteratedText"]?.stringValue ?? "").isEmpty == false { hasRomanized = true }

            let lineStartMs = lead["StartTime"]?.doubleValue.map { Int($0 * 1000) } ?? 0
            let lineEndMs   = lead["EndTime"]?.doubleValue.map { Int($0 * 1000) }
                ?? karaokeSyllables.last?.endMs
                ?? lineStartMs

            lines.append(LyricsLineDto(content: lineText.lyricsNoteIfEmpty, offsetMs: lineStartMs))

            if !karaokeSyllables.isEmpty {
                karaokeLines.append(KaraokeLineDto(
                    syllables: karaokeSyllables,
                    startMs: lineStartMs,
                    endMs: lineEndMs
                ))
            }
        }

        let romanization: LyricsRomanizationStatus = hasRomanized
            ? .romanized
            : (lines.map(\.content).canBeRomanized ? .canBeRomanized : .original)

        if !karaokeLines.isEmpty {
            let songWriters = root["SongWriters"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            let providerCode = root["source"]?.stringValue
            let providerDisplayName = providerCode == "ext" ? root["sourceName"]?.stringValue : nil

            let filledKaraokeLines = LyricsUncensorFill.fillKaraoke(
                lines: karaokeLines,
                query: query,
                options: options
            )
            let normalizedKaraokeLines = SpicyLyricsRepository.normalizeMonotonicTiming(filledKaraokeLines)

            KaraokeLyricsStore.shared.set(
                trackId: trackId,
                lyrics: KaraokeLyricsDto(
                    lines: normalizedKaraokeLines,
                    songWriters: songWriters,
                    providerCode: providerCode,
                    providerDisplayName: providerDisplayName
                )
            )
            writeDebugLog("[SpicyLyrics] Stored karaoke data: \(karaokeLines.count) lines for \(trackId)")
        }

        return LyricsDto(lines: lines, timeSynced: true, romanization: romanization)
    }

    /// Some SpicyLyrics syllable timing has slight overlaps between
    /// consecutive syllables — observed across a line boundary, where a
    /// later word's startMs lands earlier than an earlier word's endMs. This
    /// is a data quality quirk in the source's algorithmically-derived
    /// timing, not something this parsing step introduces. Left as-is, an
    /// overlap lets a LATER word's highlight progress reach further than an
    /// EARLIER word's at the same playback instant, which reads as the
    /// highlight jumping ahead on one word while lagging behind on another
    /// right next to it — reported as the highlight looking "broken" mid-
    /// line.
    ///
    /// Clamping each syllable's startMs to be at least the previous
    /// syllable's endMs — walked across the ENTIRE track in sung order,
    /// across line boundaries too, not just within one line — guarantees
    /// monotonic progress: a later syllable's window can never start before
    /// an earlier one's has finished, so highlight progress can't visually
    /// jump out of order anymore.
    private static func normalizeMonotonicTiming(_ lines: [KaraokeLineDto]) -> [KaraokeLineDto] {
        var result = lines
        var previousEndMs = Int.min
        for lineIndex in result.indices {
            for syllableIndex in result[lineIndex].syllables.indices {
                var syllable = result[lineIndex].syllables[syllableIndex]
                if syllable.startMs < previousEndMs {
                    syllable.startMs = previousEndMs
                }
                if syllable.endMs < syllable.startMs {
                    syllable.endMs = syllable.startMs
                }
                previousEndMs = syllable.endMs
                result[lineIndex].syllables[syllableIndex] = syllable
            }
        }
        return result
    }

    // MARK: Line lyrics

    private func parseLineLyrics(_ root: SLObjPackValue) -> LyricsDto {
        guard let content = root["Content"]?.arrayValue else { return emptyDto() }

        var lines        = [LyricsLineDto]()
        let hasRomanized = root["HasTransliterations"]?.boolValue ?? false

        for entry in content {
            guard entry["Type"]?.stringValue == "Vocal" else { continue }
            let text      = entry["Lead"]?["Text"]?.stringValue ?? entry["Text"]?.stringValue ?? ""
            let startTime = entry["Lead"]?["StartTime"]?.doubleValue ?? entry["StartTime"]?.doubleValue
            lines.append(LyricsLineDto(content: text.lyricsNoteIfEmpty, offsetMs: startTime.map { Int($0 * 1000) }))
        }

        let romanization: LyricsRomanizationStatus = hasRomanized
            ? .romanized
            : (lines.map(\.content).canBeRomanized ? .canBeRomanized : .original)

        return LyricsDto(lines: lines, timeSynced: true, romanization: romanization)
    }

    // MARK: Static lyrics

    private func parseStaticLyrics(_ root: SLObjPackValue) -> LyricsDto {
        let rawLines = root["Lines"]?.arrayValue ?? []
        let lines = rawLines.compactMap { entry -> LyricsLineDto? in
            guard let text = entry["Text"]?.stringValue else { return nil }
            return LyricsLineDto(content: text.lyricsNoteIfEmpty, offsetMs: nil)
        }
        let romanization: LyricsRomanizationStatus = lines.map(\.content).canBeRomanized
            ? .canBeRomanized : .original
        return LyricsDto(lines: lines, timeSynced: false, romanization: romanization)
    }

    private func emptyDto() -> LyricsDto {
        LyricsDto(lines: [], timeSynced: false, romanization: .original)
    }

    // MARK: - lrc.red Word-Synced Fallback

    private func fetchLrcRedLyrics(query: LyricsSearchQuery, trackId: String, options: LyricsOptions) throws -> LyricsDto {
        let cleanTitle = query.title
            .replacingOccurrences(of: #"(?i)\s*-\s*.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b(?:feat\.?|ft\.?|featuring)\s+.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let searchKeywords = "\(cleanTitle) \(query.primaryArtist)"
        guard let encoded = searchKeywords.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchUrl = URL(string: "https://lrc.red/search.json?q=\(encoded)") else {
            throw LyricsError.noSuchSong
        }

        var searchReq = URLRequest(url: searchUrl)
        searchReq.timeoutInterval = 4.0
        searchReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")

        let sema = DispatchSemaphore(value: 0)
        var searchData: Data?
        session.dataTask(with: searchReq) { data, _, _ in
            searchData = data
            sema.signal()
        }.resume()
        sema.wait()

        guard let sData = searchData,
              let searchJson = try? JSONSerialization.jsonObject(with: sData) as? [String: Any],
              let hits = searchJson["hits"] as? [[String: Any]],
              let firstHit = hits.first,
              let isrc = firstHit["isrc"] as? String,
              !isrc.isEmpty else {
            writeDebugLog("[LrcRed] No search hit for '\(searchKeywords)'")
            throw LyricsError.noSuchSong
        }

        guard let songUrl = URL(string: "https://lrc.red/s/\(isrc).song.json") else {
            throw LyricsError.noSuchSong
        }

        var songReq = URLRequest(url: songUrl)
        songReq.timeoutInterval = 5.0
        songReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")

        let sema2 = DispatchSemaphore(value: 0)
        var songData: Data?
        session.dataTask(with: songReq) { data, _, _ in
            songData = data
            sema2.signal()
        }.resume()
        sema2.wait()

        guard let sgData = songData,
              let songJson = try? JSONSerialization.jsonObject(with: sgData) as? [String: Any],
              let lyricsObj = songJson["lyrics"] as? [String: Any],
              let rawLines = lyricsObj["lines"] as? [[String: Any]],
              !rawLines.isEmpty else {
            writeDebugLog("[LrcRed] Empty or invalid song.json for isrc \(isrc)")
            throw LyricsError.noSuchSong
        }

        var lines = [LyricsLineDto]()
        var karaokeLines = [KaraokeLineDto]()

        for rawLine in rawLines {
            let lineText = (rawLine["text"] as? String) ?? ""
            let lineBegin = (rawLine["begin"] as? Double) ?? 0.0
            let lineEnd = (rawLine["end"] as? Double) ?? lineBegin
            let startMs = Int(lineBegin * 1000)
            let endMs = Int(lineEnd * 1000)

            lines.append(LyricsLineDto(content: lineText.lyricsNoteIfEmpty, offsetMs: startMs))

            if let wordsGroups = rawLine["words"] as? [[[String: Any]]], !wordsGroups.isEmpty {
                var lineSyllables = [KaraokeSyllableDto]()
                for wordGroup in wordsGroups {
                    for (idx, syl) in wordGroup.enumerated() {
                        let sylText = (syl["text"] as? String) ?? ""
                        let sylBegin = (syl["begin"] as? Double) ?? lineBegin
                        let sylEnd = (syl["end"] as? Double) ?? sylBegin
                        let isPartOfWord = (idx < wordGroup.count - 1)
                        lineSyllables.append(KaraokeSyllableDto(
                            text: sylText,
                            startMs: Int(sylBegin * 1000),
                            endMs: Int(sylEnd * 1000),
                            isPartOfWord: isPartOfWord
                        ))
                    }
                }
                if !lineSyllables.isEmpty {
                    karaokeLines.append(KaraokeLineDto(
                        syllables: lineSyllables,
                        startMs: startMs,
                        endMs: endMs
                    ))
                }
            }
        }

        if !karaokeLines.isEmpty {
            let filledKaraoke = LyricsUncensorFill.fillKaraoke(
                lines: karaokeLines,
                query: query,
                options: options
            )
            let normalized = SpicyLyricsRepository.normalizeMonotonicTiming(filledKaraoke)
            KaraokeLyricsStore.shared.set(
                trackId: trackId,
                lyrics: KaraokeLyricsDto(
                    lines: normalized,
                    songWriters: [],
                    providerCode: "aml",
                    providerDisplayName: "Apple Music (lrc.red)"
                )
            )
            writeDebugLog("[LrcRed] Stored word-synced karaoke: \(karaokeLines.count) lines for \(trackId)")
        } else {
            writeDebugLog("[LrcRed] Loaded line-synced lyrics: \(lines.count) lines for \(trackId)")
        }

        let romanization: LyricsRomanizationStatus = lines.map(\.content).canBeRomanized
            ? .canBeRomanized : .original

        return LyricsDto(lines: lines, timeSynced: true, romanization: romanization)
    }

    // MARK: - LyricsRepository

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let trackId = query.spotifyTrackId
        guard !trackId.isEmpty else {
            writeDebugLog("[SpicyLyrics] Empty track ID")
            throw LyricsError.noSuchSong
        }

        var dto: LyricsDto?
        do {
            let data = try performQuery(trackId: trackId)
            dto = try parseLyricsData(data, trackId: trackId, query: query, options: options)
        } catch {
            writeDebugLog("[SpicyLyrics] Primary request failed (\(error)). Trying lrc.red word-sync fallback...")
            dto = try? fetchLrcRedLyrics(query: query, trackId: trackId, options: options)
            if dto == nil {
                throw error
            }
        }

        guard var resultDto = dto else {
            throw LyricsError.noSuchSong
        }

        let filledContents = LyricsUncensorFill.fill(
            lines: resultDto.lines.map(\.content),
            query: query,
            options: options
        )
        for (index, content) in filledContents.enumerated() where index < resultDto.lines.count {
            resultDto.lines[index].content = content
        }
        return resultDto
    }
}
