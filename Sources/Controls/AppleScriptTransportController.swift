import Foundation

@MainActor
final class AppleScriptTransportController {
    func playPause() -> Bool {
        run(script: #"tell application "Spotify" to playpause"#) != nil
    }

    func nextTrack() -> Bool {
        run(script: #"tell application "Spotify" to next track"#) != nil
    }

    func previousTrack() -> Bool {
        run(script: #"tell application "Spotify" to previous track"#) != nil
    }

    func play(_ target: PlaybackTarget) -> Bool {
        let command: String
        switch target {
        case .track(let uri), .context(let uri, nil):
            command = "play track \(Self.quoted(uri))"
        case .context(let uri, let offsetURI?):
            command = "play track \(Self.quoted(offsetURI)) in context \(Self.quoted(uri))"
        }
        return run(script: "tell application \"Spotify\" to \(command)") != nil
    }

    func seek(to positionSeconds: Double) -> Bool {
        run(script: "tell application \"Spotify\" to set player position to \(max(0, positionSeconds))") != nil
    }

    /// What the local app is playing, or nil when it's stopped or can't be asked.
    func nowPlaying() -> NowPlayingSummary? {
        let script = """
        tell application "Spotify"
            if player state is stopped then return {}
            set t to current track
            return {player state as string, spotify url of t, name of t, artist of t, artwork url of t, duration of t, player position}
        end tell
        """
        guard let result = run(script: script, logsSuccess: false), result.numberOfItems == 7,
              let title = result.atIndex(3)?.stringValue
        else { return nil }
        return NowPlayingSummary(
            trackURI: result.atIndex(2)?.stringValue,
            title: title,
            artistLine: result.atIndex(4)?.stringValue ?? "",
            artworkURL: result.atIndex(5)?.stringValue.flatMap(URL.init(string:)),
            isPlaying: result.atIndex(1)?.stringValue == "playing",
            deviceName: nil,
            progressMs: result.atIndex(7).map { Int(($0.doubleValue * 1_000).rounded()) },
            durationMs: result.atIndex(6).map { Int($0.int32Value) },
            sampledAt: Date()
        )
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Moves the playhead by `offsetSeconds` within the current track and returns the new position in seconds.
    func seek(by offsetSeconds: Double) -> Double? {
        let script = """
        tell application "Spotify"
            set targetPosition to (player position) + \(offsetSeconds)
            set lastPosition to ((duration of current track) / 1000) - 1
            if targetPosition > lastPosition then set targetPosition to lastPosition
            if targetPosition < 0 then set targetPosition to 0
            set player position to targetPosition
            return targetPosition
        end tell
        """
        return run(script: script)?.doubleValue
    }

    @discardableResult
    private func run(script: String, logsSuccess: Bool = true) -> NSAppleEventDescriptor? {
        let appleScript = NSAppleScript(source: script)
        var errorDictionary: NSDictionary?
        let result = appleScript?.executeAndReturnError(&errorDictionary)
        if let errorDictionary {
            AppLogger.shared.log("AppleScript failed script=\(script) error=\(errorDictionary)", category: "transport")
            return nil
        }
        if logsSuccess {
            AppLogger.shared.log("AppleScript succeeded script=\(script)", category: "transport")
        }
        return result
    }
}
