import Foundation

enum SpotifyAPIError: LocalizedError, Equatable {
    case missingConfiguration
    case unauthorized
    case insufficientScope
    case noDevice
    case notFound
    case restrictedDevice
    case premiumRequired
    case playbackControlUnavailable
    case rateLimited(retryAfterSeconds: Int)
    case invalidResponse
    case message(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Add your Spotify Client ID before logging in."
        case .unauthorized:
            return "Spotify authorization expired. Sign in again."
        case .insufficientScope:
            return "Reconnect Spotify to grant the new permission."
        case .noDevice:
            return "Open Spotify on this Mac."
        case .notFound:
            return "Spotify couldn’t find that item."
        case .restrictedDevice:
            return "Spotify reported this device cannot be controlled."
        case .premiumRequired:
            return "Spotify Premium is required for playback control."
        case .playbackControlUnavailable:
            return "Spotify couldn't run that playback command right now."
        case .rateLimited(let seconds):
            return seconds <= 1
                ? "Spotify is limiting requests. Try again in a moment."
                : "Spotify is limiting requests. Try again in \(seconds)s."
        case .invalidResponse:
            return "Spotify returned an unexpected response."
        case .message(let message):
            return message
        }
    }
}

struct SpotifyToken: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiryDate: Date
    /// Space-separated scopes Spotify granted. Tokens saved before scopes were tracked decode as nil.
    let scope: String?

    init(accessToken: String, refreshToken: String, expiryDate: Date, scope: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiryDate = expiryDate
        self.scope = scope
    }

    var isExpired: Bool {
        expiryDate <= Date().addingTimeInterval(60)
    }

    /// nil when the token predates scope tracking, so callers should just try the request.
    func grants(_ requiredScope: String) -> Bool? {
        guard let scope else { return nil }
        return scope.split(separator: " ").contains { $0 == requiredScope }
    }
}

actor SpotifyAPIClient {
    private static let baseURL = URL(string: "https://api.spotify.com/v1")!
    private static let maxAlbumTrackPages = 4

    private let authManager: SpotifyAuthManager
    private let session: URLSession
    private let decoder = JSONDecoder()
    private var rateLimitedUntil: Date?
    private var albumTracksCache = ResponseCache<String, [SpotifyAlbumTrackItem]>(capacity: 40, timeToLive: 30 * 60)
    private var artistAlbumsCache = ResponseCache<String, [SpotifyAlbumItem]>(capacity: 20, timeToLive: 30 * 60)

    init(authManager: SpotifyAuthManager, session: URLSession = .shared) {
        self.authManager = authManager
        self.session = session
    }

    func authorizationStateForSearch() async -> SpotifyAuthorizationState {
        await authManager.authorizationStateForSearch()
    }

    /// Whether the saved token includes `scope`; nil when unknown (no token, or saved before scopes were tracked).
    func tokenGrants(_ scope: String) -> Bool? {
        (try? authManager.currentToken())?.grants(scope)
    }

    // MARK: Catalog

    func search(query: String, limit: Int = 8) async throws -> SearchResults {
        let response: SpotifySearchResponse = try await get(
            "search",
            query: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "type", value: "track,album,artist"),
                // Development-mode apps are capped at 10 results per type.
                URLQueryItem(name: "limit", value: String(max(1, min(limit, 10))))
            ]
        )
        return SearchResults(
            tracks: response.tracks?.items ?? [],
            albums: response.albums?.items ?? [],
            artists: Array((response.artists?.items ?? []).prefix(SearchResults.maxArtists))
        )
    }

    func albumTracks(albumID: String) async throws -> [SpotifyAlbumTrackItem] {
        if let cached = albumTracksCache.value(for: albumID) {
            return cached
        }

        var page: SpotifyPage<SpotifyAlbumTrackItem> = try await get(
            "albums/\(albumID)/tracks",
            query: [URLQueryItem(name: "limit", value: "50")]
        )
        var tracks = page.items
        var fetchedPages = 1
        // Long albums and box sets span several pages; follow `next` up to a sane cap.
        while let next = page.next, fetchedPages < Self.maxAlbumTrackPages {
            page = try await get(url: next)
            tracks.append(contentsOf: page.items)
            fetchedPages += 1
        }

        albumTracksCache.insert(tracks, for: albumID)
        return tracks
    }

    func artistAlbums(artistID: String) async throws -> [SpotifyAlbumItem] {
        if let cached = artistAlbumsCache.value(for: artistID) {
            return cached
        }

        let page: SpotifyPage<SpotifyAlbumItem> = try await get(
            "artists/\(artistID)/albums",
            query: [
                URLQueryItem(name: "include_groups", value: "album,single"),
                URLQueryItem(name: "limit", value: "10")
            ]
        )
        artistAlbumsCache.insert(page.items, for: artistID)
        return page.items
    }

    // MARK: Library

    func libraryContains(uris: [String]) async throws -> [Bool] {
        guard !uris.isEmpty else { return [] }
        return try await get("me/library/contains", query: [libraryURIsQueryItem(uris)])
    }

    func saveToLibrary(uris: [String]) async throws {
        try await send("PUT", "me/library", query: [libraryURIsQueryItem(uris)])
    }

    func removeFromLibrary(uris: [String]) async throws {
        try await send("DELETE", "me/library", query: [libraryURIsQueryItem(uris)])
    }

    private func libraryURIsQueryItem(_ uris: [String]) -> URLQueryItem {
        URLQueryItem(name: "uris", value: uris.prefix(40).joined(separator: ","))
    }

    // MARK: Player state

    func currentQueue() async throws -> SpotifyQueueResponse {
        try await get("me/player/queue")
    }

    func recentlyPlayedTracks(limit: Int = 20) async throws -> [SpotifyRecentlyPlayedItem] {
        let response: SpotifyRecentlyPlayedResponse = try await get(
            "me/player/recently-played",
            query: [URLQueryItem(name: "limit", value: String(max(1, min(limit, 50))))]
        )
        return response.items
    }

    func availableDevices() async throws -> [SpotifyDevice] {
        let response: SpotifyDevicesResponse = try await get("me/player/devices")
        return response.devices
    }

    func currentPlaybackState() async throws -> SpotifyPlaybackState? {
        let data = try await perform("GET", url: Self.url(for: "me/player"))
        // 204 No Content means nothing is playing anywhere.
        guard let data, !data.isEmpty else { return nil }
        return try decoder.decode(SpotifyPlaybackState.self, from: data)
    }

    // MARK: Player commands

    func transferPlayback(deviceID: String) async throws {
        try await sendPlayerCommand("PUT", "me/player", body: ["device_ids": [deviceID], "play": true])
    }

    func play(_ target: PlaybackTarget, deviceID: String?) async throws {
        try await sendPlayerCommand("PUT", "me/player/play", deviceID: deviceID, body: target.requestBody)
    }

    func queue(trackURI: String, deviceID: String) async throws {
        try await sendPlayerCommand(
            "POST",
            "me/player/queue",
            query: [URLQueryItem(name: "uri", value: trackURI)],
            deviceID: deviceID
        )
    }

    func resume(deviceID: String) async throws {
        try await sendPlayerCommand("PUT", "me/player/play", deviceID: deviceID)
    }

    func pause(deviceID: String) async throws {
        try await sendPlayerCommand("PUT", "me/player/pause", deviceID: deviceID)
    }

    func skipNext(deviceID: String) async throws {
        try await sendPlayerCommand("POST", "me/player/next", deviceID: deviceID)
    }

    func skipPrevious(deviceID: String) async throws {
        try await sendPlayerCommand("POST", "me/player/previous", deviceID: deviceID)
    }

    func seek(positionMS: Int, deviceID: String) async throws {
        try await sendPlayerCommand(
            "PUT",
            "me/player/seek",
            query: [URLQueryItem(name: "position_ms", value: String(max(0, positionMS)))],
            deviceID: deviceID
        )
    }

    // MARK: Transport

    private func get<Response: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Response {
        try await get(url: Self.url(for: path, query: query))
    }

    private func get<Response: Decodable>(url: URL) async throws -> Response {
        guard let data = try await perform("GET", url: url) else {
            throw SpotifyAPIError.invalidResponse
        }
        return try decoder.decode(Response.self, from: data)
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws {
        _ = try await perform(method, url: Self.url(for: path, query: query))
    }

    /// Player endpoints answer 404 when no device is reachable, which callers recover from by launching Spotify.
    private func sendPlayerCommand(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        deviceID: String? = nil,
        body: [String: Any]? = nil
    ) async throws {
        var query = query
        if let deviceID {
            query.append(URLQueryItem(name: "device_id", value: deviceID))
        }
        _ = try await perform(method, url: Self.url(for: path, query: query), body: body, notFoundError: .noDevice)
    }

    private func perform(
        _ method: String,
        url: URL,
        body: [String: Any]? = nil,
        notFoundError: SpotifyAPIError = .notFound
    ) async throws -> Data? {
        // While Spotify has asked us to back off, fail fast instead of adding to the pile.
        if let rateLimitedUntil {
            let remaining = rateLimitedUntil.timeIntervalSinceNow
            if remaining > 0 {
                throw SpotifyAPIError.rateLimited(retryAfterSeconds: Int(remaining.rounded(.up)))
            }
            self.rateLimitedUntil = nil
        }

        let token = try await authManager.ensureAuthorized()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        if let error = Self.error(for: httpResponse, data: data, notFoundError: notFoundError) {
            if case .rateLimited(let seconds) = error {
                rateLimitedUntil = Date().addingTimeInterval(TimeInterval(seconds))
                AppLogger.shared.log("rate limited retryAfter=\(seconds)s path=\(url.path)", category: "api")
            }
            throw error
        }
        return httpResponse.statusCode == 204 ? nil : data
    }

    private static func url(for path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
            // URLComponents leaves "+" unescaped, which servers read as a space ("C++" would search "C  ").
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url!
    }

    // MARK: Error mapping

    static func error(
        for response: HTTPURLResponse,
        data: Data?,
        notFoundError: SpotifyAPIError = .notFound
    ) -> SpotifyAPIError? {
        let message = spotifyErrorMessage(from: data)

        switch response.statusCode {
        case 200..<300:
            return nil
        case 401:
            return .unauthorized
        case 403:
            return forbiddenError(message: message)
        case 404:
            return notFoundError
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init) ?? 5
            return .rateLimited(retryAfterSeconds: max(1, retryAfter))
        default:
            if let message {
                if message.localizedCaseInsensitiveContains("premium") {
                    return .premiumRequired
                }
                return .message(message)
            }
            if response.statusCode >= 500 {
                return .message("Spotify is having trouble right now (\(response.statusCode)). Try again.")
            }
            return .message("Spotify request failed (\(response.statusCode)).")
        }
    }

    private static func forbiddenError(message: String?) -> SpotifyAPIError {
        guard let message, !message.isEmpty else {
            return .playbackControlUnavailable
        }

        let normalized = message.localizedLowercase
        if normalized.contains("scope") {
            return .insufficientScope
        }
        if normalized.contains("premium") {
            return .premiumRequired
        }
        if normalized.contains("restricted") {
            return .restrictedDevice
        }
        return .message(message)
    }

    private static func spotifyErrorMessage(from data: Data?) -> String? {
        guard
            let data,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty
        {
            return message
        }

        if let error = object["error"] as? String, !error.isEmpty {
            return error
        }

        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }

        return nil
    }
}
