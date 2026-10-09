import Foundation

struct SpotifyTrack: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let artists: [SpotifyArtist]
    let album: SpotifyAlbum
    let uri: String
    let durationMs: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, artists, album, uri
        case durationMs = "duration_ms"
    }

    var artistLine: String {
        artists.map(\.name).joined(separator: ", ")
    }

    var artworkURL: URL? {
        album.images.preferredURL()
    }

    /// Plays inside the album so playback continues after this track instead of stopping.
    var playbackTarget: PlaybackTarget {
        guard let albumURI = album.uri else { return .track(uri: uri) }
        return .context(uri: albumURI, offsetURI: uri)
    }
}

struct SpotifyArtist: Decodable, Equatable {
    let id: String?
    let name: String
    let uri: String?

    init(id: String? = nil, name: String, uri: String? = nil) {
        self.id = id
        self.name = name
        self.uri = uri
    }
}

struct SpotifyAlbum: Decodable, Equatable {
    let id: String?
    let name: String
    let images: [SpotifyImage]
    let uri: String?

    init(id: String? = nil, name: String, images: [SpotifyImage], uri: String? = nil) {
        self.id = id
        self.name = name
        self.images = images
        self.uri = uri
    }
}

struct SpotifyImage: Decodable, Equatable {
    let url: URL
    let width: Int?
    let height: Int?
}

extension Array where Element == SpotifyImage {
    /// Spotify returns roughly 640, 300 and 64 px renditions. Rows render at 40–56 pt,
    /// so the smallest rendition that still covers a 2x display avoids downloading 640 px art.
    func preferredURL(minimumPixels: Int = 112) -> URL? {
        let sized = filter { $0.width != nil }.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        if let match = sized.first(where: { ($0.width ?? 0) >= minimumPixels }) {
            return match.url
        }
        return sized.last?.url ?? first?.url
    }
}

struct SpotifySearchResponse: Decodable {
    let tracks: SpotifyPage<SpotifyTrack>?
    let albums: SpotifyPage<SpotifyAlbumItem>?
    let artists: SpotifyPage<SpotifyArtistItem>?
}

struct SpotifyPage<Item: Decodable>: Decodable {
    let items: [Item]
    let next: URL?
    let total: Int?

    enum CodingKeys: String, CodingKey {
        case items, next, total
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Spotify can return null entries inside search pages; drop them instead of failing the whole page.
        items = try container.decodeIfPresent([FailableDecodable<Item>].self, forKey: .items)?.compactMap(\.value) ?? []
        next = try? container.decodeIfPresent(URL.self, forKey: .next)
        total = try container.decodeIfPresent(Int.self, forKey: .total)
    }
}

private struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

struct SpotifyAlbumItem: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let artists: [SpotifyArtist]
    let images: [SpotifyImage]
    let uri: String
    let albumType: String?
    let totalTracks: Int?
    let releaseDate: String?

    enum CodingKeys: String, CodingKey {
        case id, name, artists, images, uri
        case albumType = "album_type"
        case totalTracks = "total_tracks"
        case releaseDate = "release_date"
    }

    init(
        id: String,
        name: String,
        artists: [SpotifyArtist],
        images: [SpotifyImage],
        uri: String,
        albumType: String?,
        totalTracks: Int?,
        releaseDate: String? = nil
    ) {
        self.id = id
        self.name = name
        self.artists = artists
        self.images = images
        self.uri = uri
        self.albumType = albumType
        self.totalTracks = totalTracks
        self.releaseDate = releaseDate
    }

    var artistLine: String {
        artists.map(\.name).joined(separator: ", ")
    }

    var artworkURL: URL? {
        images.preferredURL()
    }

    var releaseYear: String? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return String(releaseDate.prefix(4))
    }

    var summaryLine: String {
        var parts: [String] = []
        if let releaseYear { parts.append(releaseYear) }
        if let albumType, albumType != "album" { parts.append(albumType.capitalized) }
        if let totalTracks { parts.append(totalTracks == 1 ? "1 track" : "\(totalTracks) tracks") }
        return parts.joined(separator: " · ")
    }

    var albumReference: SpotifyAlbum {
        SpotifyAlbum(id: id, name: name, images: images, uri: uri)
    }
}

struct SpotifyArtistItem: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let uri: String
    let images: [SpotifyImage]

    enum CodingKeys: String, CodingKey {
        case id, name, uri, images
    }

    init(id: String, name: String, uri: String, images: [SpotifyImage]) {
        self.id = id
        self.name = name
        self.uri = uri
        self.images = images
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        uri = try container.decode(String.self, forKey: .uri)
        images = try container.decodeIfPresent([SpotifyImage].self, forKey: .images) ?? []
    }

    var artworkURL: URL? {
        images.preferredURL()
    }
}

struct SpotifyAlbumTrackItem: Decodable, Equatable {
    let id: String
    let name: String
    let artists: [SpotifyArtist]
    let uri: String
    let durationMs: Int?
    let trackNumber: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, artists, uri
        case durationMs = "duration_ms"
        case trackNumber = "track_number"
    }

    func track(in album: SpotifyAlbum) -> SpotifyTrack {
        SpotifyTrack(id: id, name: name, artists: artists, album: album, uri: uri, durationMs: durationMs)
    }
}

/// What Spotify should start playing.
enum PlaybackTarget: Equatable {
    case track(uri: String)
    /// An album, artist or playlist, optionally starting at a specific track inside it.
    case context(uri: String, offsetURI: String?)

    var requestBody: [String: Any] {
        switch self {
        case .track(let uri):
            return ["uris": [uri]]
        case .context(let uri, let offsetURI):
            var body: [String: Any] = ["context_uri": uri]
            if let offsetURI {
                body["offset"] = ["uri": offsetURI]
            }
            return body
        }
    }

    /// The single-track fallback used when Spotify rejects a context offset.
    var fallbackTrackTarget: PlaybackTarget? {
        if case .context(_, let offsetURI?) = self {
            return .track(uri: offsetURI)
        }
        return nil
    }
}

struct SpotifyQueueResponse: Decodable, Equatable {
    let currentlyPlaying: SpotifyTrack?
    let queue: [SpotifyTrack]

    enum CodingKeys: String, CodingKey {
        case currentlyPlaying = "currently_playing"
        case queue
    }

    init(currentlyPlaying: SpotifyTrack?, queue: [SpotifyTrack]) {
        self.currentlyPlaying = currentlyPlaying
        self.queue = queue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentlyPlaying = try container.decodeIfPresent(SpotifyQueueTrack.self, forKey: .currentlyPlaying)?.track
        queue = try container.decodeIfPresent([SpotifyQueueTrack].self, forKey: .queue)?.compactMap(\.track) ?? []
    }
}

struct SpotifyRecentlyPlayedResponse: Decodable, Equatable {
    let items: [SpotifyRecentlyPlayedItem]
}

struct SpotifyRecentlyPlayedItem: Decodable, Equatable {
    let track: SpotifyTrack
    let playedAt: Date?

    enum CodingKeys: String, CodingKey {
        case track
        case playedAt = "played_at"
    }

    init(track: SpotifyTrack, playedAt: Date?) {
        self.track = track
        self.playedAt = playedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        track = try container.decode(SpotifyTrack.self, forKey: .track)
        if let playedAtString = try container.decodeIfPresent(String.self, forKey: .playedAt) {
            playedAt = ISO8601DateFormatter.spotifyDate(from: playedAtString)
        } else {
            playedAt = nil
        }
    }
}

private struct SpotifyQueueTrack: Decodable {
    let track: SpotifyTrack?

    enum CodingKeys: String, CodingKey {
        case type
        case uri
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type)
        let uri = try container.decodeIfPresent(String.self, forKey: .uri)

        guard type == "track" || uri?.hasPrefix("spotify:track:") == true else {
            track = nil
            return
        }

        track = try? SpotifyTrack(from: decoder)
    }
}

private extension ISO8601DateFormatter {
    static func spotifyDate(from string: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: string) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

struct SpotifyDevice: Decodable, Equatable {
    let id: String?
    let isActive: Bool
    let isRestricted: Bool
    let name: String
    let type: String

    enum CodingKeys: String, CodingKey {
        case id
        case isActive = "is_active"
        case isRestricted = "is_restricted"
        case name
        case type
    }
}

struct SpotifyDevicesResponse: Decodable {
    let devices: [SpotifyDevice]
}

struct SpotifyPlaybackState: Decodable, Equatable {
    let device: SpotifyDevice?
    let isPlaying: Bool
    let progressMs: Int?
    let item: SpotifyPlaybackItem?

    enum CodingKeys: String, CodingKey {
        case device
        case isPlaying = "is_playing"
        case progressMs = "progress_ms"
        case item
    }
}

struct SpotifyPlaybackItem: Decodable, Equatable {
    let id: String?
    let name: String
    let artists: [SpotifyArtist]
    let album: SpotifyPlaybackAlbum?
    let uri: String?
    let durationMs: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, artists, album, uri
        case durationMs = "duration_ms"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        artists = try container.decodeIfPresent([SpotifyArtist].self, forKey: .artists) ?? []
        album = try container.decodeIfPresent(SpotifyPlaybackAlbum.self, forKey: .album)
        uri = try container.decodeIfPresent(String.self, forKey: .uri)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
    }

    var artistLine: String {
        let names = artists.map(\.name).filter { !$0.isEmpty }
        return names.isEmpty ? "Spotify" : names.joined(separator: ", ")
    }

    var artworkURL: URL? {
        album?.images.preferredURL()
    }
}

struct SpotifyPlaybackAlbum: Decodable, Equatable {
    let name: String?
    let images: [SpotifyImage]

    enum CodingKeys: String, CodingKey {
        case name, images
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        images = try container.decodeIfPresent([SpotifyImage].self, forKey: .images) ?? []
    }
}
