import XCTest
@testable import Spotlightify

final class SearchViewModelTests: XCTestCase {
    func testQueueDeduplicationRemovesCurrentTrackAndRepeatedUpcomingTracks() {
        let current = makeTrack(id: "current", name: "Current")
        let next = makeTrack(id: "next", name: "Next")
        let later = makeTrack(id: "later", name: "Later")

        let tracks = [current, current, next, next, current, later, later]

        let deduplicated = SearchViewModel.deduplicatedQueueTracks(
            tracks,
            excludingCurrentTrackID: current.id
        )

        XCTAssertEqual(deduplicated.map(\.id), ["next", "later"])
    }

    @MainActor
    func testHorizontalArrowsSwitchColumnsWithoutOpeningDetail() {
        let model = makeViewModel()
        model.applySearchResults(SearchResults(
            tracks: (0..<3).map { makeTrack(id: "song-\($0)", name: "Song") },
            albums: (0..<3).map { makeAlbum(id: "album-\($0)") }
        ))
        model.moveSelection(by: 1)

        XCTAssertTrue(model.canMoveRight)
        model.moveRight()
        XCTAssertEqual(model.focus, .browse)
        XCTAssertEqual(model.browseIndex, 1)
        XCTAssertTrue(model.detailStack.isEmpty)
        XCTAssertTrue(model.canMoveLeft)

        model.moveLeft()
        XCTAssertEqual(model.focus, .main)
        XCTAssertEqual(model.selectedIndex, 1)
        XCTAssertFalse(model.canMoveLeft)
    }

    @MainActor
    func testVerticalArrowsStayWithinEachColumn() {
        let model = makeViewModel()
        model.applySearchResults(SearchResults(
            tracks: (0..<2).map { makeTrack(id: "song-\($0)", name: "Song") },
            albums: (0..<3).map { makeAlbum(id: "album-\($0)") }
        ))
        model.moveSelection(by: 20)
        XCTAssertEqual(model.selectedIndex, 1)
        model.moveRight()
        XCTAssertEqual(model.browseIndex, 1)
        model.moveSelection(by: -20)
        XCTAssertEqual(model.browseIndex, 0)
        model.moveSelection(by: 20)
        XCTAssertEqual(model.browseIndex, 2)
        XCTAssertEqual(model.selectedIndex, 1, "Moving in the browse column must not change the song selection")
        model.moveLeft()
        XCTAssertEqual(model.selectedIndex, 1)
    }

    @MainActor
    func testHorizontalNavigationClampsToShorterColumn() {
        let model = makeViewModel()
        model.applySearchResults(SearchResults(
            tracks: (0..<4).map { makeTrack(id: "song-\($0)", name: "Song") },
            albums: [makeAlbum(id: "only-album")]
        ))
        model.moveSelection(by: 3)
        model.moveRight()
        XCTAssertEqual(model.focus, .browse)
        XCTAssertEqual(model.browseIndex, 0)
        XCTAssertTrue(model.detailStack.isEmpty)
    }

    @MainActor
    func testArtistsLeadTheBrowseColumn() {
        let model = makeViewModel()
        model.applySearchResults(SearchResults(
            tracks: [makeTrack(id: "song", name: "Song")],
            albums: [makeAlbum(id: "album")],
            artists: [makeArtist(id: "artist")]
        ))

        XCTAssertEqual(model.browseItems.map(\.id), ["artist:artist", "album:album"])
    }

    @MainActor
    func testEmptyColumnsDoNotReceiveSelection() {
        let model = makeViewModel()
        model.applySearchResults(SearchResults(tracks: [makeTrack(id: "song", name: "Song")]))
        XCTAssertFalse(model.canMoveRight)
        model.moveRight()
        XCTAssertEqual(model.focus, .main)

        model.applySearchResults(SearchResults(albums: [makeAlbum(id: "only-album")]))
        XCTAssertEqual(model.focus, .browse, "With no songs, selection starts in the browse column")
        XCTAssertFalse(model.canMoveLeft)
        model.moveLeft()
        model.moveSelection(by: -1)
        XCTAssertEqual(model.browseIndex, 0)

        model.applySearchResults(SearchResults())
        XCTAssertEqual(model.panelState, .empty)
        XCTAssertFalse(model.canMoveRight)
        XCTAssertFalse(model.canMoveLeft)
        XCTAssertFalse(model.hasSelection)
    }

    @MainActor
    func testOpeningAndClosingDetailRestoresBrowseSelection() {
        let model = makeViewModel()
        model.applySearchResults(SearchResults(
            tracks: [makeTrack(id: "song", name: "Song")],
            albums: (0..<3).map { makeAlbum(id: "album-\($0)") }
        ))
        model.moveRight()
        model.moveSelection(by: 2)
        model.moveRight()

        XCTAssertEqual(model.focus, .detail)
        XCTAssertEqual(model.currentDetail?.page, .album(makeAlbum(id: "album-2")))

        model.moveLeft()
        XCTAssertEqual(model.focus, .browse)
        XCTAssertTrue(model.detailStack.isEmpty)
        XCTAssertEqual(model.browseIndex, 2)
    }

    @MainActor
    func testRightFromSongsReturnsToOpenDetail() {
        let model = makeViewModel()
        model.applySearchResults(SearchResults(
            tracks: [makeTrack(id: "song", name: "Song")],
            artists: [makeArtist(id: "artist")]
        ))
        model.activateBrowseItem(at: 0)
        XCTAssertEqual(model.focus, .detail)

        model.moveLeft()
        model.moveLeft()
        XCTAssertEqual(model.focus, .main)
        XCTAssertTrue(model.detailStack.isEmpty)

        model.activateBrowseItem(at: 0)
        XCTAssertEqual(model.currentDetail?.page, .artist(makeArtist(id: "artist")))
    }

    @MainActor
    func testPlayingASongUsesItsAlbumAsContext() async {
        let model = makeViewModel()
        let played = expectation(description: "play requested")
        var requestedTarget: PlaybackTarget?
        model.onPlayRequested = { target, _ in
            requestedTarget = target
            played.fulfill()
        }
        model.applySearchResults(SearchResults(tracks: [makeTrack(id: "song", name: "Song", albumID: "album")]))

        model.activateSelection()
        await fulfillment(of: [played], timeout: 1)

        XCTAssertEqual(requestedTarget, .context(uri: "spotify:album:album", offsetURI: "spotify:track:song"))
    }

    @MainActor
    func testShiftEnterOnBrowseItemPlaysWholeContext() async {
        let model = makeViewModel()
        let played = expectation(description: "play requested")
        var requestedTarget: PlaybackTarget?
        model.onPlayRequested = { target, _ in
            requestedTarget = target
            played.fulfill()
        }
        model.applySearchResults(SearchResults(artists: [makeArtist(id: "artist")]))

        model.playSelectionContext()
        await fulfillment(of: [played], timeout: 1)

        XCTAssertEqual(requestedTarget, .context(uri: "spotify:artist:artist", offsetURI: nil))
        XCTAssertTrue(model.detailStack.isEmpty, "Shift+Enter plays without drilling in")
    }

    @MainActor
    func testRetypedQueryIsServedFromCacheWithoutLoading() {
        let model = makeViewModel()
        model.isSpotifyConfigured = { true }
        let results = SearchResults(tracks: [makeTrack(id: "song", name: "Song")])
        model.cacheSearchResultsForTesting(results, query: "Daft  Punk")

        model.query = "daft punk "

        XCTAssertEqual(model.panelState, .results(results), "Cached results render without the debounce")
    }

    @MainActor
    func testUncachedQueryShowsLoadingWhileDebouncing() {
        let model = makeViewModel()
        model.isSpotifyConfigured = { true }

        model.query = "something new"

        XCTAssertEqual(model.panelState, .loading)
    }

    @MainActor
    func testSeekMovesNowPlayingPositionImmediately() {
        let model = makeViewModel()
        let summary = makeSummary(progressMs: 10_000, isPlaying: false)
        model.showNowPlayingForTesting(summary)

        model.requestSeek(to: 90_000)

        guard case .showing(let updated) = model.nowPlayingState else {
            return XCTFail("Expected now playing")
        }
        XCTAssertEqual(updated.progressMs(at: Date()), 90_000)
    }

    @MainActor
    func testPlayerEventForSameTrackUpdatesStateWithoutRefetch() {
        let model = makeViewModel()
        model.showNowPlayingForTesting(makeSummary(progressMs: 10_000, isPlaying: true))

        model.applyPlayerEvent(SpotifyPlayerEvent(
            state: .paused,
            trackURI: "spotify:track:now",
            title: "Now",
            artist: "Artist",
            positionMs: 42_000,
            durationMs: 200_000
        ))

        guard case .showing(let updated) = model.nowPlayingState else {
            return XCTFail("Expected now playing")
        }
        XCTAssertFalse(updated.isPlaying)
        XCTAssertEqual(updated.progressMs(at: Date().addingTimeInterval(30)), 42_000)
        XCTAssertFalse(model.nowPlayingRefreshInProgress)
    }

    @MainActor
    func testPlayerEventForNewTrackWhileClosedUpdatesFromBroadcast() {
        let model = makeViewModel()
        model.showNowPlayingForTesting(makeSummary(progressMs: 10_000, isPlaying: true))

        model.applyPlayerEvent(SpotifyPlayerEvent(
            state: .playing,
            trackURI: "spotify:track:next",
            title: "Next Song",
            artist: "Other Artist",
            positionMs: 0,
            durationMs: 150_000
        ))

        guard case .showing(let updated) = model.nowPlayingState else {
            return XCTFail("Expected now playing")
        }
        XCTAssertEqual(updated.trackURI, "spotify:track:next")
        XCTAssertEqual(updated.title, "Next Song")
        XCTAssertFalse(model.nowPlayingRefreshInProgress, "A closed panel should not hit the API for a local track change")

        model.applyPlayerEvent(SpotifyPlayerEvent(
            state: .stopped, trackURI: nil, title: nil, artist: nil, positionMs: nil, durationMs: nil
        ))
        XCTAssertEqual(model.nowPlayingState, .hidden)
    }

    // MARK: Helpers

    @MainActor
    private func makeViewModel() -> SearchViewModel {
        let configuration = AppConfiguration(bundledSpotifyClientID: "test", callbackScheme: "spotlightify")
        let authManager = SpotifyAuthManager(
            configuration: configuration,
            keychain: KeychainStore(service: "search-navigation-tests"),
            // An empty client ID makes any accidental API call fail fast instead of starting a browser login.
            clientIDProvider: { "" },
            session: .shared
        )
        return SearchViewModel(
            apiClient: SpotifyAPIClient(authManager: authManager),
            redirectURI: "spotlightify://callback"
        )
    }

    private func makeSummary(progressMs: Int, isPlaying: Bool) -> NowPlayingSummary {
        NowPlayingSummary(
            trackURI: "spotify:track:now",
            title: "Now",
            artistLine: "Artist",
            artworkURL: nil,
            isPlaying: isPlaying,
            deviceName: "Mac",
            progressMs: progressMs,
            durationMs: 200_000,
            sampledAt: Date()
        )
    }

    private func makeAlbum(id: String) -> SpotifyAlbumItem {
        SpotifyAlbumItem(
            id: id, name: "Album", artists: [], images: [],
            uri: "spotify:album:\(id)", albumType: "album", totalTracks: 10
        )
    }

    private func makeArtist(id: String) -> SpotifyArtistItem {
        SpotifyArtistItem(id: id, name: "Artist", uri: "spotify:artist:\(id)", images: [])
    }

    private func makeTrack(id: String, name: String, albumID: String = "album") -> SpotifyTrack {
        let json = """
        {
          "id": "\(id)",
          "name": "\(name)",
          "type": "track",
          "uri": "spotify:track:\(id)",
          "duration_ms": 180000,
          "artists": [{ "name": "Artist" }],
          "album": {
            "id": "\(albumID)",
            "name": "Album",
            "uri": "spotify:album:\(albumID)",
            "images": []
          }
        }
        """
        return try! JSONDecoder().decode(SpotifyTrack.self, from: Data(json.utf8))
    }
}
