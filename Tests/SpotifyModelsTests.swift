import XCTest
@testable import Spotlightify

final class SpotifyModelsTests: XCTestCase {
    func testQueueResponseDecodesTracksAndFiltersEpisodes() throws {
        let json = """
        {
          "currently_playing": \(trackJSON(id: "current", name: "Now Track")),
          "queue": [
            \(trackJSON(id: "next", name: "Next Track")),
            {
              "id": "episode-1",
              "name": "Podcast Episode",
              "type": "episode",
              "uri": "spotify:episode:episode-1"
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(SpotifyQueueResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.currentlyPlaying?.id, "current")
        XCTAssertEqual(response.queue.map(\.id), ["next"])
    }

    func testRecentlyPlayedResponseDecodesTrackAndPlayedAt() throws {
        let json = """
        {
          "items": [
            {
              "track": \(trackJSON(id: "recent", name: "Recent Track")),
              "played_at": "2026-05-18T10:12:30.123Z"
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(SpotifyRecentlyPlayedResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.items.first?.track.id, "recent")
        XCTAssertNotNil(response.items.first?.playedAt)
    }

    func testSearchResponseDecodesArtistsAndSkipsNullItems() throws {
        let json = """
        {
          "tracks": { "items": [\(trackJSON(id: "t", name: "Track")), null], "next": null, "total": 1 },
          "artists": {
            "items": [{ "id": "a", "name": "The Strokes", "uri": "spotify:artist:a", "images": [] }],
            "next": "https://api.spotify.com/v1/search?offset=8",
            "total": 40
          }
        }
        """

        let response = try JSONDecoder().decode(SpotifySearchResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.tracks?.items.map(\.id), ["t"])
        XCTAssertEqual(response.artists?.items.first?.name, "The Strokes")
        XCTAssertNotNil(response.artists?.next)
        XCTAssertNil(response.albums)
    }

    func testTracksPlayInsideTheirAlbum() throws {
        let track = try JSONDecoder().decode(SpotifyTrack.self, from: Data(trackJSON(id: "t", name: "Track").utf8))

        XCTAssertEqual(track.playbackTarget, .context(uri: "spotify:album:test-album", offsetURI: "spotify:track:t"))
        XCTAssertEqual(track.playbackTarget.fallbackTrackTarget, .track(uri: "spotify:track:t"))
    }

    func testPlaybackTargetRequestBodies() {
        XCTAssertEqual(PlaybackTarget.track(uri: "spotify:track:t").requestBody["uris"] as? [String], ["spotify:track:t"])

        let context = PlaybackTarget.context(uri: "spotify:album:a", offsetURI: "spotify:track:t").requestBody
        XCTAssertEqual(context["context_uri"] as? String, "spotify:album:a")
        XCTAssertEqual((context["offset"] as? [String: String])?["uri"], "spotify:track:t")

        let wholeAlbum = PlaybackTarget.context(uri: "spotify:album:a", offsetURI: nil).requestBody
        XCTAssertNil(wholeAlbum["offset"])
        XCTAssertNil(PlaybackTarget.context(uri: "spotify:album:a", offsetURI: nil).fallbackTrackTarget)
    }

    func testArtworkPrefersSmallestImageThatCoversRetinaRows() {
        let images = [640, 300, 64].map { (size: Int) in
            SpotifyImage(url: URL(string: "https://i.scdn.co/\(size)")!, width: size, height: size)
        }

        XCTAssertEqual(images.preferredURL()?.lastPathComponent, "300")
        XCTAssertEqual(images.preferredURL(minimumPixels: 500)?.lastPathComponent, "640")
        XCTAssertEqual(images.preferredURL(minimumPixels: 2_000)?.lastPathComponent, "640")
    }

    private func trackJSON(id: String, name: String) -> String {
        """
        {
          "id": "\(id)",
          "name": "\(name)",
          "type": "track",
          "uri": "spotify:track:\(id)",
          "duration_ms": 210000,
          "artists": [{ "name": "The Strokes" }],
          "album": {
            "id": "test-album",
            "uri": "spotify:album:test-album",
            "name": "Test Album",
            "images": [
              { "url": "https://example.com/cover.jpg", "width": 300, "height": 300 }
            ]
          }
        }
        """
    }
}
