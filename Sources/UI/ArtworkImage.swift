import AppKit
import SwiftUI

/// Shared album-art cache. Decoded images live in memory so rows that scroll or
/// re-render show art instantly; raw responses go to a disk-backed URLCache so
/// art survives relaunches. Concurrent requests for one URL share a download.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let memory = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<Data?, Never>] = [:]
    private let session: URLSession

    init() {
        memory.countLimit = 400

        let configuration = URLSessionConfiguration.default
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        configuration.urlCache = URLCache(
            memoryCapacity: 8 * 1_024 * 1_024,
            diskCapacity: 100 * 1_024 * 1_024,
            directory: cachesDirectory?.appendingPathComponent("Spotlightify/Artwork", isDirectory: true)
        )
        // Spotify image URLs are content-addressed, so a cached copy never goes stale.
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
    }

    func cachedImage(for url: URL) -> NSImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = cachedImage(for: url) {
            return cached
        }

        let task: Task<Data?, Never>
        if let existing = inFlight[url] {
            task = existing
        } else {
            let session = session
            task = Task {
                guard let (data, response) = try? await session.data(from: url),
                      let httpResponse = response as? HTTPURLResponse,
                      200..<300 ~= httpResponse.statusCode
                else {
                    return nil
                }
                return data
            }
            inFlight[url] = task
        }

        let data = await task.value
        inFlight[url] = nil
        if let cached = cachedImage(for: url) {
            return cached
        }
        guard let data, let image = NSImage(data: data) else { return nil }
        memory.setObject(image, forKey: url as NSURL)
        return image
    }
}

struct ArtworkImage: View {
    let url: URL?
    var size: CGFloat
    var cornerRadius: CGFloat = 9
    var isCircular = false
    var placeholderSymbol = "music.note"

    @State private var loaded: (url: URL, image: NSImage)?

    var body: some View {
        ZStack {
            if let image = displayedImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.overlayInk.opacity(0.055)
                    .overlay {
                        Image(systemName: placeholderSymbol)
                            .font(.system(size: max(11, size * 0.3), weight: .medium))
                            .foregroundStyle(Color.inkFaint)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: isCircular ? size / 2 : cornerRadius, style: .continuous))
        .task(id: url) {
            guard let url, ArtworkCache.shared.cachedImage(for: url) == nil else { return }
            if let image = await ArtworkCache.shared.image(for: url), !Task.isCancelled {
                loaded = (url, image)
            }
        }
    }

    private var displayedImage: NSImage? {
        guard let url else { return nil }
        if let loaded, loaded.url == url {
            return loaded.image
        }
        return ArtworkCache.shared.cachedImage(for: url)
    }
}
