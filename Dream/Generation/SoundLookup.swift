import Foundation

/// Real recordings from Wikimedia Commons, found the way `Lookup` finds a subject's image: one
/// search, then the best file iOS can play, with its credit and licence.
enum SoundLookup {
    static func find(_ search: String) async -> Recording? {
        let words = stems(search)
        guard !words.isEmpty, let response = await query(search) else { return nil }
        // Search ranks by text, so a file can turn up for a single word of a longer search;
        // one that shares fewer than half the search's words is a wrong turn. Of the rest: the
        // one that matches most, short rather than long, since a page wants the call itself and
        // not an hour of a marsh at dawn, then the one whose title is most nearly the search.
        let candidates = (response.query?.pages ?? []).compactMap { page -> (rank: [Int], recording: Recording)? in
            guard let info = page.videoinfo?.first, let recording = recording(page.title, info) else { return nil }
            let about = [page.title, info.field("ImageDescription"), info.field("Categories")].joined(separator: " ")
            let shared = words.intersection(stems(stripped(about))).count
            guard shared * 2 > words.count else { return nil }
            let length = recording.duration ?? 30
            guard length < 600 else { return nil }
            let extra = stems(recording.title).subtracting(words).count
            return ([shared * 2 - (length > 90 ? 1 : 0), -extra, -(page.index ?? 0)], recording)
        }
        return candidates.max { $0.rank.lexicographicallyPrecedes($1.rank) }?.recording
    }

    /// A version AVPlayer streams: MP3, AAC or WAV as uploaded, else Commons' own MP3 of the file.
    /// MIDI is skipped: it's a score played by a synthesizer, not a recording.
    private static func recording(_ title: String, _ info: Response.Info) -> Recording? {
        let mime = info.mime ?? ""
        guard !mime.contains("midi") else { return nil }
        let native = ["audio/mpeg", "audio/mp3", "audio/mp4", "audio/aac", "audio/x-m4a", "audio/wav", "audio/x-wav", "audio/wave"]
        let mp3 = info.derivatives?.first { $0.type.hasPrefix("audio/mpeg") }?.src
        let original = native.contains(mime) ? info.url : nil
        // Commons' MP3 is far smaller than a WAV original.
        guard let source = mime == "audio/mpeg" ? original : mp3 ?? original,
              var components = URLComponents(string: source.hasPrefix("//") ? "https:" + source : source)
        else { return nil }
        components.query = nil
        guard let audio = components.url?.absoluteString else { return nil }
        let name = title.replacing(#/^File:/#, with: "").replacing(#/\.[A-Za-z0-9]+$/#, with: "")
        return Recording(
            title: stripped(info.field("ObjectName")).isEmpty ? name : stripped(info.field("ObjectName")),
            audioURL: audio,
            pageURL: info.descriptionurl ?? "https://commons.wikimedia.org/wiki/\(title.replacingOccurrences(of: " ", with: "_"))",
            credit: credit(info.field("Artist")),
            licence: stripped(info.field("LicenseShortName")),
            duration: info.duration.flatMap { $0 > 0 ? $0 : nil })
    }

    /// Who made it, as plain text. A list of roles (speaker, recorder) keeps only the first.
    private static func credit(_ html: String) -> String {
        var text = html
        if let item = html.firstMatch(of: #/<li>(.*?)</li>/#.dotMatchesNewlines()) { text = String(item.output.1) }
        text = stripped(text)
        guard text.count > 80 else { return text }
        return String(text.prefix(80).split(separator: " ").dropLast().joined(separator: " ")) + "…"
    }

    /// Commons' descriptions are HTML.
    private static func stripped(_ html: String) -> String {
        let entities = ["&amp;": "&", "&quot;": "\"", "&#039;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        var text = html.replacing(#/<[^>]+>/#, with: " ")
        for (entity, character) in entities { text = text.replacingOccurrences(of: entity, with: character) }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func stems(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
            .map { $0.hasSuffix("s") && $0.count > 3 ? String($0.dropLast()) : $0 })
    }

    private static func query(_ search: String) async -> Response? {
        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "gsrsearch", value: "\(search) filetype:audio"),
            URLQueryItem(name: "gsrlimit", value: "8"),
            URLQueryItem(name: "prop", value: "videoinfo"),
            URLQueryItem(name: "viprop", value: "url|size|mime|extmetadata|derivatives"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Dream/0.1 (iOS prototype)", forHTTPHeaderField: "User-Agent")
        for attempt in 0..<2 {
            guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
            // Commons asks busy clients to slow down; one more try, a moment later.
            if (response as? HTTPURLResponse)?.statusCode == 429, attempt == 0 {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            return try? JSONDecoder().decode(Response.self, from: data)
        }
        return nil
    }

    private struct Response: Decodable {
        let query: Query?

        struct Query: Decodable {
            let pages: [Page]?
        }

        struct Page: Decodable {
            let title: String
            let index: Int?
            let videoinfo: [Info]?
        }

        struct Info: Decodable {
            let url: String?
            let descriptionurl: String?
            let mime: String?
            let duration: Double?
            let extmetadata: [String: Field]?
            let derivatives: [Derivative]?

            func field(_ name: String) -> String { extmetadata?[name]?.value ?? "" }
        }

        struct Derivative: Decodable {
            let src: String
            let type: String
        }

        /// Most metadata values are text; the few that are numbers aren't needed.
        struct Field: Decodable {
            let value: String?

            init(from decoder: Decoder) throws {
                value = try? decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .value)
            }

            enum Keys: String, CodingKey { case value }
        }
    }
}

extension Surface {
    /// Finds a recording for every sound that asks for one, all at once. A sound that finds
    /// nothing is left without, and the checker drops it.
    mutating func findRecordings() async {
        guard let sounds else { return }
        let wanted = sounds.indices.filter { sounds[$0].isRecording && sounds[$0].recording == nil && !sounds[$0].search.isEmpty }
        guard !wanted.isEmpty else { return }
        let found = await withTaskGroup(of: (Int, Recording?).self) { group in
            for index in wanted {
                let search = sounds[index].search
                group.addTask { (index, await SoundLookup.find(search)) }
            }
            return await group.reduce(into: [Int: Recording]()) { $0[$1.0] = $1.1 }
        }
        for (index, recording) in found {
            self.sounds?[index].recording = recording
        }
    }
}
