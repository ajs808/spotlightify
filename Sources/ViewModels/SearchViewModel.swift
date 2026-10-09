import Foundation

enum NowPlayingState: Equatable {
    case hidden
    case loading
    case showing(NowPlayingSummary)
}

struct NowPlayingSummary: Equatable {
    let trackURI: String?
    let title: String
    let artistLine: String
    let artworkURL: URL?
    let isPlaying: Bool
    let deviceName: String?
    let progressMs: Int?
    let durationMs: Int?
    /// When `progressMs` was measured, so the position can advance locally between API reads.
    let sampledAt: Date

    /// The playback position at `date`, counting forward from the last sample while playing.
    func progressMs(at date: Date) -> Int? {
        guard let progressMs else { return nil }
        guard isPlaying else { return progressMs }
        let elapsedMs = max(0, Int(date.timeIntervalSince(sampledAt) * 1_000))
        let live = progressMs + elapsedMs
        return durationMs.map { min(live, $0) } ?? live
    }

    func progressFraction(at date: Date) -> Double? {
        guard let position = progressMs(at: date), let durationMs, durationMs > 0 else { return nil }
        return min(max(Double(position) / Double(durationMs), 0), 1)
    }

    func remainingMs(at date: Date) -> Int? {
        guard let position = progressMs(at: date), let durationMs else { return nil }
        return max(0, durationMs - position)
    }

    func with(isPlaying: Bool? = nil, progressMs: Int?, sampledAt: Date) -> NowPlayingSummary {
        NowPlayingSummary(
            trackURI: trackURI,
            title: title,
            artistLine: artistLine,
            artworkURL: artworkURL,
            isPlaying: isPlaying ?? self.isPlaying,
            deviceName: deviceName,
            progressMs: progressMs,
            durationMs: durationMs,
            sampledAt: sampledAt
        )
    }
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = "" {
        didSet {
            if !query.isEmpty {
                activeMode = .search
                clearMessage()
            }
            startDebouncedSearch(for: query)
        }
    }
    @Published private(set) var activeMode: SearchPanelMode = .search
    @Published private(set) var focus: SearchFocus = .main
    /// Selection in the main list: songs in search mode, or the Recent / Queue list.
    @Published private(set) var selectedIndex = 0
    /// Selection in the artists + albums column.
    @Published private(set) var browseIndex = 0
    /// The album / artist pages opened from the browse column, innermost last.
    @Published private(set) var detailStack: [DetailEntry] = []
    @Published private(set) var panelState: SearchPanelState = .helper
    @Published private(set) var recentState: TrackCollectionState = .idle
    @Published private(set) var queueState: TrackCollectionState = .idle
    @Published private(set) var inlineMessage: String?
    @Published private(set) var inlineMessageIsError = false
    @Published private(set) var inlineMessageIsLoading = false
    @Published private(set) var loginInProgress = false
    @Published private(set) var focusRequestID = UUID()
    @Published private(set) var nowPlayingState: NowPlayingState = .hidden {
        didSet { nowPlayingStateDidChange(from: oldValue) }
    }
    @Published private(set) var nowPlayingRefreshInProgress = false
    /// Known Liked Songs membership by track URI. Missing means "not checked yet".
    @Published private(set) var likedTrackURIs: [String: Bool] = [:]
    @Published var setupClientID = ""
    @Published var hasSavedClientID = false

    var onPlayRequested: ((PlaybackTarget, String) async -> Void)?
    var onQueueRequested: (([String], String) async -> Void)?
    var onSeekRequested: ((Int) async -> Void)?
    var onLoginRequested: (() -> Void)?
    var onSaveClientIDRequested: ((String) -> Void)?
    var onClearConfigurationRequested: (() -> Void)?
    var onOpenSpotifyRequested: (() -> Void)?
    var onNowPlayingChanged: ((NowPlayingSummary?) -> Void)?
    var isSpotifyConfigured: (() -> Bool)?
    var currentConfiguredClientID: (() -> String)?

    let redirectURI: String
    private let apiClient: SpotifyAPIClient
    private let debounceDelay: Duration
    private var searchCache = ResponseCache<String, SearchResults>(capacity: 40, timeToLive: 5 * 60)
    private var searchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var nowPlayingTask: Task<Void, Never>?
    private var nowPlayingRefreshID = UUID()
    private var trackEndRefreshTask: Task<Void, Never>?
    private var recentTask: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?
    private var messageClearTask: Task<Void, Never>?
    private var pendingSelectionOffset = 0
    private var isPresented = false
    /// Set once Spotify says the token lacks library scopes, to stop asking until the user reconnects.
    private var libraryAccessDenied = false

    init(apiClient: SpotifyAPIClient, redirectURI: String, debounceDelay: Duration = .milliseconds(250)) {
        self.apiClient = apiClient
        self.redirectURI = redirectURI
        self.debounceDelay = debounceDelay
    }

    // MARK: Derived state

    var searchResults: SearchResults? {
        guard activeMode == .search, case .results(let results) = panelState else { return nil }
        return results
    }

    var searchTrackItems: [TrackListItem] {
        (searchResults?.tracks ?? []).map { TrackListItem(track: $0) }
    }

    var browseItems: [BrowseItem] {
        searchResults?.browseItems ?? []
    }

    var currentDetail: DetailEntry? {
        detailStack.last
    }

    var hasSelection: Bool {
        selectionCount > 0
    }

    var canHandleSelectionMovement: Bool {
        hasSelection || focusedListIsLoading
    }

    var canMoveRight: Bool {
        guard searchResults != nil else { return false }
        switch focus {
        case .main:
            return !detailStack.isEmpty || !browseItems.isEmpty
        case .browse:
            return browseItems.indices.contains(browseIndex)
        case .detail:
            return selectedDetailAlbum != nil
        }
    }

    var canMoveLeft: Bool {
        switch focus {
        case .main:
            return false
        case .browse:
            return !searchTrackItems.isEmpty
        case .detail:
            return true
        }
    }

    var canSwitchModes: Bool {
        switch panelState {
        case .setupRequired, .authenticationRequired:
            return false
        default:
            return true
        }
    }

    func isLiked(_ uri: String?) -> Bool {
        guard let uri else { return false }
        return likedTrackURIs[uri] == true
    }

    // MARK: Presentation

    func setPresented(_ presented: Bool) {
        isPresented = presented
    }

    func prepareForPresentation() {
        clearMessage()
        searchTask?.cancel()
        nowPlayingTask?.cancel()
        recentTask?.cancel()
        queueTask?.cancel()
        recentState = .idle
        queueState = .idle

        guard isSpotifyConfigured?() != false else {
            nowPlayingState = .hidden
            presentSetup(clientID: currentConfiguredClientID?() ?? "", hasSavedClientID: hasSavedClientID)
            return
        }

        Task {
            let authorizationState = await apiClient.authorizationStateForSearch()

            switch authorizationState {
            case .requiresInteractiveLogin:
                showAuthenticationRequired("Sign in to Spotify to search.")
            case .interactiveLoginInProgress:
                showAuthenticationRequired("Finish Spotify login in the browser.")
            case .ready:
                refreshNowPlaying()
                switch activeMode {
                case .search:
                    if query.isEmpty {
                        resetSelection()
                        panelState = .helper
                    } else {
                        performSearch(for: query)
                    }
                case .recent:
                    fetchRecentTracks(force: true)
                case .queue:
                    fetchQueue(force: true)
                }
            }
        }
    }

    func setMode(_ mode: SearchPanelMode) {
        guard activeMode != mode else { return }
        activeMode = mode
        resetSelection()
        clearMessage()

        switch mode {
        case .search:
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                panelState = isSpotifyConfigured?() == false ? .setupRequired : .helper
            } else {
                performSearch(for: query)
            }
        case .recent:
            fetchRecentTracks(force: false)
        case .queue:
            fetchQueue(force: false)
        }
    }

    func cycleMode(backwards: Bool = false) {
        let modes = SearchPanelMode.allCases
        guard let currentIndex = modes.firstIndex(of: activeMode) else {
            setMode(.search)
            return
        }

        let offset = backwards ? modes.count - 1 : 1
        setMode(modes[(currentIndex + offset) % modes.count])
    }

    // MARK: Keyboard navigation

    func moveSelection(by offset: Int) {
        let count = selectionCount
        guard count > 0 else {
            if focusedListIsLoading {
                pendingSelectionOffset = max(0, pendingSelectionOffset + offset)
            }
            return
        }

        switch focus {
        case .main:
            selectedIndex = clamp(selectedIndex + offset, count: count)
        case .browse:
            browseIndex = clamp(browseIndex + offset, count: count)
        case .detail:
            detailStack[detailStack.count - 1].selectedIndex = clamp(detailStack[detailStack.count - 1].selectedIndex + offset, count: count)
        }
    }

    func moveRight() {
        guard canMoveRight else { return }
        switch focus {
        case .main:
            if !detailStack.isEmpty {
                focus = .detail
            } else {
                // Land on the row beside the current song.
                browseIndex = clamp(selectedIndex, count: browseItems.count)
                focus = .browse
            }
        case .browse, .detail:
            activateSelection()
        }
    }

    func moveLeft() {
        switch focus {
        case .main:
            return
        case .browse:
            guard !searchTrackItems.isEmpty else { return }
            selectedIndex = clamp(browseIndex, count: searchTrackItems.count)
            focus = .main
        case .detail:
            popDetail()
        }
    }

    /// Enter: play a song, or open an artist / album.
    func activateSelection() {
        switch focus {
        case .main:
            guard let track = selectedMainItem?.track else { return }
            requestPlay(track.playbackTarget, label: track.name)
        case .browse:
            guard let item = selectedBrowseItem else { return }
            openDetail(item.detailPage)
        case .detail:
            if let track = selectedDetailTrack {
                requestPlay(track.playbackTarget, label: track.name)
            } else if let album = selectedDetailAlbum {
                openDetail(.album(album))
            }
        }
    }

    /// Shift+Enter: play the whole album or artist instead of drilling in.
    func playSelectionContext() {
        switch focus {
        case .main:
            activateSelection()
        case .browse:
            guard let item = selectedBrowseItem else { return }
            playContext(of: item.detailPage)
        case .detail:
            if let album = selectedDetailAlbum {
                playContext(of: .album(album))
            } else if let page = currentDetail?.page {
                playContext(of: page)
            }
        }
    }

    /// Cmd+Enter: queue a song, or every track on an album.
    func queueSelection() {
        switch focus {
        case .main:
            guard let track = selectedMainItem?.track else { return }
            requestQueue([track.uri], label: track.name)
        case .browse:
            switch selectedBrowseItem {
            case .album(let album):
                queueAlbum(album)
            case .artist:
                showTransientMessage("Open the artist and pick an album to queue.")
            case nil:
                return
            }
        case .detail:
            if let track = selectedDetailTrack {
                requestQueue([track.uri], label: track.name)
            } else if let album = selectedDetailAlbum {
                queueAlbum(album)
            }
        }
    }

    /// Cmd+L: like the highlighted song, or what's playing when nothing is highlighted.
    func toggleLikeForSelection() {
        if let track = selectedTrack {
            toggleLike(uri: track.uri, name: track.name)
        } else if case .showing(let summary) = nowPlayingState, let uri = summary.trackURI {
            toggleLike(uri: uri, name: summary.title)
        }
    }

    // MARK: Mouse

    func activateMainItem(at index: Int) {
        guard mainItems.indices.contains(index) else { return }
        selectedIndex = index
        focus = .main
        activateSelection()
    }

    func activateBrowseItem(at index: Int) {
        guard browseItems.indices.contains(index) else { return }
        browseIndex = index
        focus = .browse
        activateSelection()
    }

    func activateDetailItem(at index: Int) {
        guard let entry = currentDetail, index >= 0, index < entry.content.itemCount else { return }
        detailStack[detailStack.count - 1].selectedIndex = index
        focus = .detail
        activateSelection()
    }

    func playCurrentDetail() {
        guard let page = currentDetail?.page else { return }
        playContext(of: page)
    }

    func popDetail() {
        guard let removed = detailStack.popLast() else { return }
        detailTask?.cancel()

        if let parent = detailStack.last {
            focus = .detail
            if parent.content == .loading {
                loadDetail(parent.page)
            }
        } else {
            if let index = browseItems.firstIndex(where: { $0.detailPage == removed.page }) {
                browseIndex = index
            }
            focus = browseItems.isEmpty ? .main : .browse
        }
    }

    // MARK: Likes

    func toggleLike(uri: String, name: String) {
        guard uri.hasPrefix("spotify:track:") else {
            showTransientMessage("Only Spotify tracks can be added to Liked Songs.", isError: true)
            return
        }

        Task {
            if await apiClient.tokenGrants(SpotifyAuthManager.libraryModifyScope) == false {
                libraryAccessDenied = true
                setInlineMessage("Reconnect Spotify to allow liking songs.")
                return
            }

            do {
                let wasLiked: Bool
                if let known = likedTrackURIs[uri] {
                    wasLiked = known
                } else {
                    wasLiked = try await apiClient.libraryContains(uris: [uri]).first ?? false
                }

                if wasLiked {
                    try await apiClient.removeFromLibrary(uris: [uri])
                } else {
                    try await apiClient.saveToLibrary(uris: [uri])
                }
                likedTrackURIs[uri] = !wasLiked
                showTransientMessage(wasLiked ? "Removed \(name) from Liked Songs" : "Added \(name) to Liked Songs")
            } catch SpotifyAPIError.insufficientScope {
                libraryAccessDenied = true
                setInlineMessage("Reconnect Spotify to allow liking songs.")
            } catch {
                setInlineMessage(error.localizedDescription)
            }
        }
    }

    /// Call after a fresh login so newly granted scopes are used.
    func resetLibraryAccess() {
        libraryAccessDenied = false
        likedTrackURIs.removeAll()
    }

    // MARK: Messages and requests

    func setInlineMessage(_ message: String, isError: Bool = true, isLoading: Bool = false) {
        messageClearTask?.cancel()
        inlineMessage = message
        inlineMessageIsError = isError
        inlineMessageIsLoading = isLoading && !isError
    }

    /// Shows a confirmation that clears itself unless something replaced it.
    func showTransientMessage(_ message: String, isError: Bool = false, duration: Duration = .seconds(2)) {
        setInlineMessage(message, isError: isError)
        messageClearTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, inlineMessage == message else { return }
            clearMessage()
        }
    }

    func clearMessage() {
        messageClearTask?.cancel()
        inlineMessage = nil
        inlineMessageIsError = false
        inlineMessageIsLoading = false
    }

    func requestLogin() {
        guard !loginInProgress else { return }
        onLoginRequested?()
    }

    func requestOpenSpotify() {
        onOpenSpotifyRequested?()
    }

    func requestSeek(to positionMS: Int) {
        let position = max(0, positionMS)
        // Move the bar immediately; the refresh after the seek confirms it.
        if case .showing(let summary) = nowPlayingState {
            nowPlayingState = .showing(summary.with(progressMs: position, sampledAt: Date()))
        }
        Task {
            await onSeekRequested?(position)
        }
    }

    func retrySearchIfNeeded() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        performSearch(for: query)
    }

    func setLoginInProgress(_ inProgress: Bool) {
        loginInProgress = inProgress
    }

    func presentSetup(clientID: String, hasSavedClientID: Bool) {
        searchTask?.cancel()
        recentTask?.cancel()
        queueTask?.cancel()
        activeMode = .search
        resetSelection()
        recentState = .idle
        queueState = .idle
        nowPlayingState = .hidden
        setupClientID = clientID
        self.hasSavedClientID = hasSavedClientID
        panelState = .setupRequired
        requestSearchFocus()
    }

    func saveClientID() {
        onSaveClientIDRequested?(setupClientID)
    }

    func clearConfiguration() {
        onClearConfigurationRequested?()
    }

    func requestSearchFocus() {
        focusRequestID = UUID()
    }

    func clearQuery() {
        query = ""
    }

    // MARK: Now playing

    func refreshNowPlaying() {
        nowPlayingTask?.cancel()
        let refreshID = UUID()
        nowPlayingRefreshID = refreshID

        guard canShowNowPlaying else {
            nowPlayingState = .hidden
            nowPlayingRefreshInProgress = false
            return
        }

        let isPreservingCurrentContent: Bool
        if case .showing = nowPlayingState {
            isPreservingCurrentContent = true
            nowPlayingRefreshInProgress = true
        } else {
            isPreservingCurrentContent = false
            nowPlayingState = .loading
            nowPlayingRefreshInProgress = false
        }

        nowPlayingTask = Task {
            defer {
                if nowPlayingRefreshID == refreshID {
                    nowPlayingRefreshInProgress = false
                }
            }

            do {
                let playbackState = try await apiClient.currentPlaybackState()
                guard !Task.isCancelled else { return }
                guard let summary = Self.makeNowPlayingSummary(from: playbackState, sampledAt: Date()) else {
                    nowPlayingState = .hidden
                    return
                }
                nowPlayingState = .showing(summary)
                // The heart is only visible in the panel, so don't spend a request on it otherwise.
                if isPresented {
                    checkLikedState(for: summary.trackURI)
                }
            } catch {
                guard !Task.isCancelled else { return }
                if !isPreservingCurrentContent {
                    nowPlayingState = .hidden
                }
            }
        }
    }

    /// Applies a broadcast from the local Spotify app. Play/pause and position changes on the
    /// same track update in place. A new track is read from the API only while the panel is
    /// open (for artwork and device); otherwise the broadcast itself is enough, and opening
    /// the panel refreshes anyway.
    func applyPlayerEvent(_ event: SpotifyPlayerEvent) {
        guard canShowNowPlaying else { return }
        let now = Date()

        if event.state != .stopped,
           case .showing(let summary) = nowPlayingState,
           let uri = event.trackURI,
           uri == summary.trackURI
        {
            nowPlayingState = .showing(summary.with(
                isPlaying: event.state == .playing,
                progressMs: event.positionMs ?? summary.progressMs(at: now),
                sampledAt: now
            ))
        } else if isPresented {
            refreshNowPlaying()
        } else if event.state == .stopped {
            nowPlayingState = .hidden
        } else if let title = event.title {
            nowPlayingState = .showing(NowPlayingSummary(
                trackURI: event.trackURI,
                title: title,
                artistLine: event.artist ?? "",
                artworkURL: nil,
                isPlaying: event.state == .playing,
                deviceName: nil,
                progressMs: event.positionMs,
                durationMs: event.durationMs,
                sampledAt: now
            ))
        }
    }

    func refreshQueueAfterPlaybackChange() {
        if activeMode == .queue || queueState.hasLoadedContent {
            fetchQueue(force: true)
        }
    }

    func clearNowPlaying() {
        nowPlayingTask?.cancel()
        nowPlayingRefreshID = UUID()
        nowPlayingRefreshInProgress = false
        nowPlayingState = .hidden
    }

    // MARK: Search results

    func applySearchResults(_ results: SearchResults) {
        detailTask?.cancel()
        detailStack = []

        guard !results.isEmpty else {
            pendingSelectionOffset = 0
            selectedIndex = 0
            browseIndex = 0
            focus = .main
            panelState = .empty
            return
        }

        panelState = .results(results)
        // Pending arrow presses made while loading belong to the first nonempty column.
        if results.tracks.isEmpty {
            focus = .browse
            selectedIndex = 0
            browseIndex = consumePendingSelectionIndex(itemCount: results.browseItems.count)
        } else {
            focus = .main
            selectedIndex = consumePendingSelectionIndex(itemCount: results.tracks.count)
            browseIndex = 0
        }
    }
}

// MARK: - Private

extension SearchViewModel {
    private var mainItems: [TrackListItem] {
        switch activeMode {
        case .search:
            return searchTrackItems
        case .recent:
            if case .loaded(let items) = recentState { return items }
            return []
        case .queue:
            if case .loaded(let items) = queueState { return items }
            return []
        }
    }

    private var selectionCount: Int {
        switch focus {
        case .main: return mainItems.count
        case .browse: return browseItems.count
        case .detail: return currentDetail?.content.itemCount ?? 0
        }
    }

    private var selectedMainItem: TrackListItem? {
        mainItems.indices.contains(selectedIndex) ? mainItems[selectedIndex] : nil
    }

    private var selectedBrowseItem: BrowseItem? {
        browseItems.indices.contains(browseIndex) ? browseItems[browseIndex] : nil
    }

    private var selectedDetailTrack: SpotifyTrack? {
        guard let entry = currentDetail, case .tracks(let items) = entry.content,
              items.indices.contains(entry.selectedIndex) else { return nil }
        return items[entry.selectedIndex].track
    }

    private var selectedDetailAlbum: SpotifyAlbumItem? {
        guard let entry = currentDetail, case .albums(let albums) = entry.content,
              albums.indices.contains(entry.selectedIndex) else { return nil }
        return albums[entry.selectedIndex]
    }

    /// The song under the keyboard selection, if the focused row is a song.
    private var selectedTrack: SpotifyTrack? {
        switch focus {
        case .main: return selectedMainItem?.track
        case .browse: return nil
        case .detail: return selectedDetailTrack
        }
    }

    private var focusedListIsLoading: Bool {
        switch focus {
        case .detail:
            return currentDetail?.content == .loading
        case .browse:
            return false
        case .main:
            switch activeMode {
            case .search:
                return panelState == .loading
            case .recent:
                return recentState == .loading
            case .queue:
                return queueState == .loading
            }
        }
    }

    private var canShowNowPlaying: Bool {
        switch panelState {
        case .setupRequired, .authenticationRequired:
            return false
        default:
            return true
        }
    }

    private func clamp(_ index: Int, count: Int) -> Int {
        max(0, min(count - 1, index))
    }

    private func consumePendingSelectionIndex(itemCount: Int) -> Int {
        defer { pendingSelectionOffset = 0 }
        guard itemCount > 0 else { return 0 }
        return min(itemCount - 1, pendingSelectionOffset)
    }

    private func resetSelection() {
        detailTask?.cancel()
        detailStack = []
        focus = .main
        selectedIndex = 0
        browseIndex = 0
        pendingSelectionOffset = 0
    }

    private func showAuthenticationRequired(_ message: String) {
        resetSelection()
        nowPlayingState = .hidden
        panelState = .authenticationRequired(message)
    }

    private func requestPlay(_ target: PlaybackTarget, label: String) {
        Task { await onPlayRequested?(target, label) }
    }

    private func requestQueue(_ uris: [String], label: String) {
        Task { await onQueueRequested?(uris, label) }
    }

    private func playContext(of page: DetailPage) {
        requestPlay(.context(uri: page.contextURI, offsetURI: nil), label: page.title)
    }

    private func queueAlbum(_ album: SpotifyAlbumItem) {
        setInlineMessage("Queueing \(album.name)…", isError: false, isLoading: true)
        Task {
            do {
                let tracks = try await apiClient.albumTracks(albumID: album.id)
                guard !tracks.isEmpty else {
                    showTransientMessage("\(album.name) has no playable tracks.", isError: true)
                    return
                }
                await onQueueRequested?(tracks.map(\.uri), album.name)
            } catch {
                setInlineMessage(error.localizedDescription)
            }
        }
    }

    private func openDetail(_ page: DetailPage) {
        guard currentDetail?.page != page else {
            focus = .detail
            return
        }
        pendingSelectionOffset = 0
        detailStack.append(DetailEntry(page: page))
        focus = .detail
        loadDetail(page)
    }

    private func loadDetail(_ page: DetailPage) {
        detailTask?.cancel()
        detailTask = Task {
            let content: DetailContent
            do {
                switch page {
                case .album(let album):
                    let albumReference = album.albumReference
                    let items = try await apiClient.albumTracks(albumID: album.id).map {
                        TrackListItem(track: $0.track(in: albumReference))
                    }
                    content = items.isEmpty ? .empty : .tracks(items)
                case .artist(let artist):
                    let albums = try await apiClient.artistAlbums(artistID: artist.id)
                    content = albums.isEmpty ? .empty : .albums(albums)
                }
            } catch {
                guard !Task.isCancelled else { return }
                content = .error(Self.libraryErrorMessage(error, fallback: "Couldn’t load \(page.title)."))
            }

            guard !Task.isCancelled,
                  let index = detailStack.lastIndex(where: { $0.page == page }) else { return }
            detailStack[index].content = content
            detailStack[index].selectedIndex = consumePendingSelectionIndex(itemCount: content.itemCount)
        }
    }

    static func normalizedQuery(_ query: String) -> String {
        query
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func startDebouncedSearch(for query: String) {
        debounceTask?.cancel()
        searchTask?.cancel()

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        resetSelection()
        guard !trimmedQuery.isEmpty else {
            if activeMode == .search {
                panelState = isSpotifyConfigured?() == false ? .setupRequired : .helper
            }
            return
        }

        // Retyped or backspaced queries render instantly without another request.
        if let cached = searchCache.value(for: Self.normalizedQuery(trimmedQuery)) {
            applySearchResults(cached)
            return
        }

        if isSpotifyConfigured?() != false {
            panelState = .loading
        }

        debounceTask = Task {
            do {
                try await Task.sleep(for: debounceDelay)
            } catch {
                return
            }
            performSearch(for: trimmedQuery)
        }
    }

    private func performSearch(for query: String) {
        searchTask?.cancel()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            if activeMode == .search {
                resetSelection()
                panelState = isSpotifyConfigured?() == false ? .setupRequired : .helper
            }
            return
        }

        searchTask = Task {
            guard self.isSpotifyConfigured?() != false else {
                self.presentSetup(clientID: self.currentConfiguredClientID?() ?? "", hasSavedClientID: self.hasSavedClientID)
                return
            }

            let authorizationState = await apiClient.authorizationStateForSearch()
            guard !Task.isCancelled else { return }

            switch authorizationState {
            case .requiresInteractiveLogin:
                showAuthenticationRequired("Sign in to Spotify to search.")
                return
            case .interactiveLoginInProgress:
                showAuthenticationRequired("Finish Spotify login in the browser.")
                return
            case .ready:
                break
            }

            let cacheKey = Self.normalizedQuery(trimmedQuery)
            if let cached = searchCache.value(for: cacheKey) {
                applySearchResults(cached)
                return
            }
            panelState = .loading

            do {
                let results = try await apiClient.search(query: trimmedQuery)
                guard !Task.isCancelled else { return }
                searchCache.insert(results, for: cacheKey)
                applySearchResults(results)
            } catch {
                guard !Task.isCancelled else { return }
                panelState = .error(error.localizedDescription)
            }
        }
    }

    private func fetchRecentTracks(force: Bool) {
        guard isSpotifyConfigured?() != false else {
            presentSetup(clientID: currentConfiguredClientID?() ?? "", hasSavedClientID: hasSavedClientID)
            return
        }
        if !force, recentState.shouldSkipFetch { return }

        recentTask?.cancel()
        recentState = .loading
        selectedIndex = 0
        pendingSelectionOffset = 0
        recentTask = Task {
            do {
                let items = try await apiClient.recentlyPlayedTracks(limit: 20)
                guard !Task.isCancelled else { return }
                let rows = items.map { item in
                    TrackListItem(
                        id: "recent-\(item.playedAt?.timeIntervalSince1970 ?? 0)-\(item.track.id)",
                        track: item.track,
                        metadata: Self.relativePlayedTime(from: item.playedAt)
                    )
                }
                recentState = rows.isEmpty ? .empty : .loaded(rows)
                selectedIndex = consumePendingSelectionIndex(itemCount: rows.count)
            } catch {
                guard !Task.isCancelled else { return }
                recentState = .error(Self.libraryErrorMessage(error, fallback: "Couldn't load recent tracks."))
            }
        }
    }

    private func fetchQueue(force: Bool) {
        guard isSpotifyConfigured?() != false else {
            presentSetup(clientID: currentConfiguredClientID?() ?? "", hasSavedClientID: hasSavedClientID)
            return
        }
        if !force, queueState.shouldSkipFetch { return }

        queueTask?.cancel()
        queueState = .loading
        selectedIndex = 0
        pendingSelectionOffset = 0
        queueTask = Task {
            do {
                let response = try await apiClient.currentQueue()
                guard !Task.isCancelled else { return }
                var rows: [TrackListItem] = []
                if let currentlyPlaying = response.currentlyPlaying {
                    rows.append(
                        TrackListItem(
                            id: "queue-current-\(currentlyPlaying.id)",
                            track: currentlyPlaying,
                            metadata: "Now playing"
                        )
                    )
                }
                let upcomingTracks = Self.deduplicatedQueueTracks(
                    response.queue,
                    excludingCurrentTrackID: response.currentlyPlaying?.id
                )
                rows.append(
                    contentsOf: upcomingTracks.enumerated().map { index, track in
                        TrackListItem(
                            id: "queue-\(index)-\(track.id)",
                            track: track,
                            metadata: "#\(index + 1) in queue"
                        )
                    }
                )
                queueState = rows.isEmpty ? .empty : .loaded(rows)
                selectedIndex = consumePendingSelectionIndex(itemCount: rows.count)
            } catch {
                guard !Task.isCancelled else { return }
                queueState = .error(Self.libraryErrorMessage(error, fallback: "Couldn't load the queue."))
            }
        }
    }

    private func nowPlayingStateDidChange(from oldValue: NowPlayingState) {
        guard oldValue != nowPlayingState else { return }
        switch nowPlayingState {
        case .showing(let summary):
            onNowPlayingChanged?(summary)
            scheduleTrackEndRefresh(for: summary)
        case .hidden:
            onNowPlayingChanged?(nil)
            trackEndRefreshTask?.cancel()
        case .loading:
            break
        }
    }

    /// Re-reads playback just after the current track should end, so the dock and menu bar
    /// roll over to the next song without polling. Local Spotify broadcasts usually arrive
    /// first and reschedule this, so it only costs a request for playback on other devices.
    private func scheduleTrackEndRefresh(for summary: NowPlayingSummary) {
        trackEndRefreshTask?.cancel()
        guard summary.isPlaying,
              let remainingMs = summary.remainingMs(at: Date()),
              remainingMs < 60 * 60 * 1_000 else { return }

        trackEndRefreshTask = Task {
            do {
                // The floor stops a track that reports no time left from re-reading in a tight loop.
                try await Task.sleep(for: .milliseconds(max(remainingMs + 1_500, 5_000)))
            } catch {
                return
            }
            refreshNowPlaying()
        }
    }

    private func checkLikedState(for uri: String?) {
        guard let uri, uri.hasPrefix("spotify:track:"), likedTrackURIs[uri] == nil, !libraryAccessDenied else { return }
        Task {
            guard await apiClient.tokenGrants(SpotifyAuthManager.libraryModifyScope) != false else {
                libraryAccessDenied = true
                return
            }
            do {
                if let liked = try await apiClient.libraryContains(uris: [uri]).first {
                    likedTrackURIs[uri] = liked
                }
            } catch SpotifyAPIError.insufficientScope {
                libraryAccessDenied = true
            } catch {
                AppLogger.shared.log("liked-state check failed error=\(error.localizedDescription)", category: "library")
            }
        }
    }

    private static func makeNowPlayingSummary(from playbackState: SpotifyPlaybackState?, sampledAt: Date) -> NowPlayingSummary? {
        guard let playbackState, let item = playbackState.item else {
            return nil
        }

        return NowPlayingSummary(
            trackURI: item.uri,
            title: item.name,
            artistLine: item.artistLine,
            artworkURL: item.artworkURL,
            isPlaying: playbackState.isPlaying,
            deviceName: playbackState.device?.name,
            progressMs: playbackState.progressMs,
            durationMs: item.durationMs,
            sampledAt: sampledAt
        )
    }

    private static func relativePlayedTime(from date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Played \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private static func libraryErrorMessage(_ error: Error, fallback: String) -> String {
        if let apiError = error as? SpotifyAPIError {
            switch apiError {
            case .unauthorized:
                return "Reconnect Spotify to enable this view."
            default:
                return apiError.localizedDescription
            }
        }
        return error.localizedDescription.isEmpty ? fallback : error.localizedDescription
    }

    nonisolated static func deduplicatedQueueTracks(
        _ tracks: [SpotifyTrack],
        excludingCurrentTrackID currentTrackID: String?
    ) -> [SpotifyTrack] {
        var seenTrackIDs = Set<String>()
        if let currentTrackID {
            seenTrackIDs.insert(currentTrackID)
        }

        return tracks.filter { track in
            guard !seenTrackIDs.contains(track.id) else { return false }
            seenTrackIDs.insert(track.id)
            return true
        }
    }
}

#if DEBUG
extension SearchViewModel {
    func cacheSearchResultsForTesting(_ results: SearchResults, query: String) {
        searchCache.insert(results, for: Self.normalizedQuery(query))
    }

    func showNowPlayingForTesting(_ summary: NowPlayingSummary) {
        nowPlayingState = .showing(summary)
    }
}
#endif

private extension TrackCollectionState {
    var shouldSkipFetch: Bool {
        switch self {
        case .loading, .loaded, .empty:
            return true
        case .idle, .error:
            return false
        }
    }

    var hasLoadedContent: Bool {
        if case .loaded = self { return true }
        return false
    }
}
