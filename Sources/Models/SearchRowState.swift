import Foundation

/// Which list keyboard navigation currently drives.
enum SearchFocus: Equatable {
    /// Songs in search mode, or the single list in Recent and Queue.
    case main
    /// Artists and albums beside the songs.
    case browse
    /// The album or artist page opened from the browse column.
    case detail
}

struct SearchResults: Equatable {
    static let maxArtists = 3

    let tracks: [SpotifyTrack]
    let albums: [SpotifyAlbumItem]
    let artists: [SpotifyArtistItem]

    init(tracks: [SpotifyTrack] = [], albums: [SpotifyAlbumItem] = [], artists: [SpotifyArtistItem] = []) {
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
    }

    var isEmpty: Bool {
        tracks.isEmpty && albums.isEmpty && artists.isEmpty
    }

    /// Artists first, then albums: the order of the right-hand column.
    var browseItems: [BrowseItem] {
        artists.map(BrowseItem.artist) + albums.map(BrowseItem.album)
    }
}

enum BrowseItem: Identifiable, Equatable {
    case artist(SpotifyArtistItem)
    case album(SpotifyAlbumItem)

    var id: String {
        switch self {
        case .artist(let artist): return "artist:\(artist.id)"
        case .album(let album): return "album:\(album.id)"
        }
    }

    var uri: String {
        switch self {
        case .artist(let artist): return artist.uri
        case .album(let album): return album.uri
        }
    }

    var detailPage: DetailPage {
        switch self {
        case .artist(let artist): return .artist(artist)
        case .album(let album): return .album(album)
        }
    }
}

enum DetailPage: Equatable {
    case album(SpotifyAlbumItem)
    case artist(SpotifyArtistItem)

    var id: String {
        switch self {
        case .album(let album): return "album:\(album.id)"
        case .artist(let artist): return "artist:\(artist.id)"
        }
    }

    var contextURI: String {
        switch self {
        case .album(let album): return album.uri
        case .artist(let artist): return artist.uri
        }
    }

    var title: String {
        switch self {
        case .album(let album): return album.name
        case .artist(let artist): return artist.name
        }
    }
}

enum DetailContent: Equatable {
    case loading
    case tracks([TrackListItem])
    case albums([SpotifyAlbumItem])
    case empty
    case error(String)

    var itemCount: Int {
        switch self {
        case .tracks(let items): return items.count
        case .albums(let albums): return albums.count
        case .loading, .empty, .error: return 0
        }
    }
}

/// One page in the right-hand drill-down (artist → album → tracks).
struct DetailEntry: Equatable {
    let page: DetailPage
    var content: DetailContent = .loading
    var selectedIndex = 0
}

enum SearchPanelState: Equatable {
    case setupRequired
    case helper
    case loading
    case authenticationRequired(String)
    case results(SearchResults)
    case empty
    case error(String)
}

enum SearchPanelMode: String, CaseIterable, Identifiable, Equatable {
    case search
    case recent
    case queue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search:
            return "Search"
        case .recent:
            return "Recent"
        case .queue:
            return "Queue"
        }
    }
}

enum TrackCollectionState: Equatable {
    case idle
    case loading
    case loaded([TrackListItem])
    case empty
    case error(String)
}

struct TrackListItem: Identifiable, Equatable {
    let id: String
    let track: SpotifyTrack
    let metadata: String?

    init(id: String? = nil, track: SpotifyTrack, metadata: String? = nil) {
        self.id = id ?? track.id
        self.track = track
        self.metadata = metadata
    }
}
