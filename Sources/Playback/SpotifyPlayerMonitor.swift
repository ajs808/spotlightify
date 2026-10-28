import AppKit
import Foundation

/// A snapshot of the local Spotify app's player, as broadcast by Spotify itself.
struct SpotifyPlayerEvent: Equatable {
    enum State: Equatable {
        case playing
        case paused
        case stopped
    }

    let state: State
    let trackURI: String?
    let title: String?
    let artist: String?
    let positionMs: Int?
    let durationMs: Int?

    /// Parses `com.spotify.client.PlaybackStateChanged`. Position arrives in seconds, duration in milliseconds.
    init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo, let rawState = userInfo["Player State"] as? String else { return nil }
        switch rawState {
        case "Playing": state = .playing
        case "Paused": state = .paused
        case "Stopped": state = .stopped
        default: return nil
        }
        trackURI = userInfo["Track ID"] as? String
        title = userInfo["Name"] as? String
        artist = userInfo["Artist"] as? String
        positionMs = (userInfo["Playback Position"] as? NSNumber).map { Int(($0.doubleValue * 1_000).rounded()) }
        durationMs = (userInfo["Duration"] as? NSNumber)?.intValue
    }

    init(state: State, trackURI: String?, title: String?, artist: String?, positionMs: Int?, durationMs: Int?) {
        self.state = state
        self.trackURI = trackURI
        self.title = title
        self.artist = artist
        self.positionMs = positionMs
        self.durationMs = durationMs
    }
}

/// Listens for the Spotify desktop app's own playback broadcasts, so track and
/// play/pause changes show up instantly without polling the Web API.
@MainActor
final class SpotifyPlayerMonitor: NSObject {
    private nonisolated static let spotifyBundleIdentifier = "com.spotify.client"
    private nonisolated static let playbackStateChanged = Notification.Name("com.spotify.client.PlaybackStateChanged")

    var onEvent: ((SpotifyPlayerEvent) -> Void)?
    var onSpotifyQuit: (() -> Void)?

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var isObservingPlayback = false

    func start() {
        guard observers.isEmpty else { return }

        // AppKit holds distributed notifications while the app is inactive, i.e. whenever the panel is closed.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(playbackStateDidChange(_:)),
            name: Self.playbackStateChanged,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        isObservingPlayback = true

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let terminationObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard application?.bundleIdentifier == Self.spotifyBundleIdentifier else { return }
            MainActor.assumeIsolated {
                self?.onSpotifyQuit?()
            }
        }
        observers.append((workspaceCenter, terminationObserver))
    }

    @objc private func playbackStateDidChange(_ notification: Notification) {
        guard let event = SpotifyPlayerEvent(userInfo: notification.userInfo) else { return }
        onEvent?(event)
    }

    func stop() {
        if isObservingPlayback {
            DistributedNotificationCenter.default().removeObserver(self, name: Self.playbackStateChanged, object: nil)
            isObservingPlayback = false
        }
        for (center, observer) in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }
}
