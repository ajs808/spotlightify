import XCTest
@testable import Spotlightify

final class NowPlayingTests: XCTestCase {
    func testProgressAdvancesWhilePlayingAndStopsAtDuration() {
        let start = Date(timeIntervalSince1970: 1_000)
        let summary = makeSummary(progressMs: 10_000, durationMs: 20_000, isPlaying: true, sampledAt: start)

        XCTAssertEqual(summary.progressMs(at: start.addingTimeInterval(5)), 15_000)
        XCTAssertEqual(summary.progressMs(at: start.addingTimeInterval(60)), 20_000)
        XCTAssertEqual(summary.remainingMs(at: start.addingTimeInterval(4)), 6_000)
    }

    func testProgressHoldsWhilePaused() {
        let start = Date(timeIntervalSince1970: 1_000)
        let summary = makeSummary(progressMs: 10_000, durationMs: 20_000, isPlaying: false, sampledAt: start)

        XCTAssertEqual(summary.progressMs(at: start.addingTimeInterval(30)), 10_000)
        XCTAssertEqual(summary.progressFraction(at: start.addingTimeInterval(30)), 0.5)
    }

    func testPlayerEventParsesSpotifyBroadcast() {
        let event = SpotifyPlayerEvent(userInfo: [
            "Player State": "Playing",
            "Track ID": "spotify:track:abc",
            "Name": "Song",
            "Artist": "Artist",
            "Playback Position": NSNumber(value: 12.5),
            "Duration": NSNumber(value: 180_000)
        ])

        XCTAssertEqual(event, SpotifyPlayerEvent(
            state: .playing,
            trackURI: "spotify:track:abc",
            title: "Song",
            artist: "Artist",
            positionMs: 12_500,
            durationMs: 180_000
        ))
    }

    func testPlayerEventIgnoresUnknownPayloads() {
        XCTAssertNil(SpotifyPlayerEvent(userInfo: nil))
        XCTAssertNil(SpotifyPlayerEvent(userInfo: ["Player State": "Buffering"]))
    }

    func testMenuBarTitleOnlyShowsWhilePlayingAndTruncates() {
        let playing = MenuBarNowPlaying(title: "Harder, Better, Faster, Stronger", artist: "Daft Punk", isPlaying: true)
        let paused = MenuBarNowPlaying(title: "Song", artist: "Artist", isPlaying: false)

        XCTAssertNil(StatusBarController.menuBarTitle(for: nil))
        XCTAssertNil(StatusBarController.menuBarTitle(for: paused))
        XCTAssertEqual(StatusBarController.menuBarTitle(for: playing, maxLength: 100), "Harder, Better, Faster, Stronger — Daft Punk")

        let truncated = StatusBarController.menuBarTitle(for: playing, maxLength: 20)
        XCTAssertEqual(truncated?.count, 20)
        XCTAssertEqual(truncated?.hasSuffix("…"), true)
    }

    private func makeSummary(progressMs: Int, durationMs: Int, isPlaying: Bool, sampledAt: Date) -> NowPlayingSummary {
        NowPlayingSummary(
            trackURI: "spotify:track:now",
            title: "Now",
            artistLine: "Artist",
            artworkURL: nil,
            isPlaying: isPlaying,
            deviceName: nil,
            progressMs: progressMs,
            durationMs: durationMs,
            sampledAt: sampledAt
        )
    }
}
