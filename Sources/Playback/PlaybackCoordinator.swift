import Foundation

actor PlaybackCoordinator {
    /// How long a resolved device ID is trusted before re-running device discovery.
    private static let deviceCacheLifetime: TimeInterval = 30 * 60
    /// `Host.current()` can block on name resolution, so read it once.
    private static let localComputerName = Host.current().localizedName ?? ""

    private let apiClient: SpotifyAPIClient
    private let now: @Sendable () -> Date
    private var cachedDevice: (device: AddressableSpotifyDevice, resolvedAt: Date)?

    init(apiClient: SpotifyAPIClient, now: @escaping @Sendable () -> Date = Date.init) {
        self.apiClient = apiClient
        self.now = now
    }

    func play(_ target: PlaybackTarget) async throws {
        // Fast path: reuse the last device that worked and skip device discovery.
        if let device = validCachedDevice {
            do {
                try await sendPlay(target, deviceID: device.id)
                return
            } catch let error as SpotifyAPIError where error == .noDevice || error == .restrictedDevice {
                AppLogger.shared.log("cached device rejected; rediscovering error=\(error)", category: "playback")
                cachedDevice = nil
            }
        }

        guard let device = try await findPlaybackDevice() else {
            AppLogger.shared.log("device discovery empty; trying Spotify active-device playback", category: "playback")
            try await sendPlay(target, deviceID: nil)
            return
        }
        if !device.isActive {
            try await apiClient.transferPlayback(deviceID: device.id)
        }
        try await sendPlay(target, deviceID: device.id)
        remember(device)
    }

    func queue(trackURIs: [String]) async throws {
        guard !trackURIs.isEmpty else { return }
        try await withPlaybackDevice(transferIfInactive: false) { apiClient, device in
            // Spotify's queue endpoint takes one URI per call; keep album order.
            for uri in trackURIs {
                try await apiClient.queue(trackURI: uri, deviceID: device.id)
            }
        }
    }

    func playPause() async throws {
        if let playbackState = try await apiClient.currentPlaybackState(),
           playbackState.isPlaying {
            let device = try resolvedAddressableDevice(from: playbackState.device)
            try await apiClient.pause(deviceID: device.id)
            return
        }

        try await withPlaybackDevice { apiClient, device in
            try await apiClient.resume(deviceID: device.id)
        }
    }

    func nextTrack() async throws {
        try await withPlaybackDevice { apiClient, device in
            try await apiClient.skipNext(deviceID: device.id)
        }
    }

    func previousTrack() async throws {
        if let playbackState = try await apiClient.currentPlaybackState(),
           let currentDevice = try? resolvedAddressableDevice(from: playbackState.device),
           let progressMs = playbackState.progressMs,
           progressMs > 3_000
        {
            if !currentDevice.isActive {
                try await apiClient.transferPlayback(deviceID: currentDevice.id)
            }
            try await apiClient.seek(positionMS: 0, deviceID: currentDevice.id)
            return
        }

        try await withPlaybackDevice { apiClient, device in
            do {
                try await apiClient.skipPrevious(deviceID: device.id)
            } catch let error as SpotifyAPIError {
                if case .message(let message) = error,
                   message.localizedCaseInsensitiveContains("restriction violated")
                {
                    try await apiClient.seek(positionMS: 0, deviceID: device.id)
                    return
                }
                throw error
            }
        }
    }

    func seek(to positionMS: Int) async throws {
        try await withPlaybackDevice { apiClient, device in
            try await apiClient.seek(positionMS: max(0, positionMS), deviceID: device.id)
        }
    }

    func forgetCachedDevice() {
        cachedDevice = nil
    }

    func resolvePlaybackDevice(
        from devices: [SpotifyDevice],
        currentPlaybackDevice: SpotifyDevice? = nil
    ) throws -> AddressableSpotifyDevice {
        guard let device = PlaybackCoordinator.preferredDevice(from: devices)
            ?? PlaybackCoordinator.preferredCurrentDevice(currentPlaybackDevice)
        else {
            throw SpotifyAPIError.noDevice
        }
        return try resolvedAddressableDevice(from: device)
    }

    // MARK: Private

    private var validCachedDevice: AddressableSpotifyDevice? {
        guard let cachedDevice, now().timeIntervalSince(cachedDevice.resolvedAt) < Self.deviceCacheLifetime else {
            return nil
        }
        return cachedDevice.device
    }

    private func remember(_ device: AddressableSpotifyDevice) {
        // After a successful command the device is the active one.
        cachedDevice = (AddressableSpotifyDevice(id: device.id, isActive: true), now())
    }

    /// Plays at a track inside a context, falling back to the bare track if Spotify
    /// rejects the offset (for example a relinked track that is not in the album).
    private func sendPlay(_ target: PlaybackTarget, deviceID: String?) async throws {
        do {
            try await apiClient.play(target, deviceID: deviceID)
        } catch let error as SpotifyAPIError {
            guard let fallback = target.fallbackTrackTarget, error.allowsPlaybackFallback else { throw error }
            AppLogger.shared.log("context playback failed; retrying single track error=\(error)", category: "playback")
            try await apiClient.play(fallback, deviceID: deviceID)
        }
    }

    /// Runs a command against the cached device, rediscovering once if Spotify no longer knows it.
    private func withPlaybackDevice(
        transferIfInactive: Bool = true,
        _ command: (SpotifyAPIClient, AddressableSpotifyDevice) async throws -> Void
    ) async throws {
        if let device = validCachedDevice {
            do {
                try await command(apiClient, device)
                return
            } catch let error as SpotifyAPIError where error == .noDevice || error == .restrictedDevice {
                AppLogger.shared.log("cached device rejected; rediscovering error=\(error)", category: "playback")
                cachedDevice = nil
            }
        }

        let device = try await resolvePlaybackDevice()
        if transferIfInactive, !device.isActive {
            try await apiClient.transferPlayback(deviceID: device.id)
        }
        try await command(apiClient, device)
        remember(device)
    }

    private func resolvePlaybackDevice() async throws -> AddressableSpotifyDevice {
        guard let device = try await findPlaybackDevice() else {
            throw SpotifyAPIError.noDevice
        }
        return device
    }

    private func findPlaybackDevice() async throws -> AddressableSpotifyDevice? {
        let devices = try await apiClient.availableDevices()
        if let device = PlaybackCoordinator.preferredDevice(from: devices) {
            return try resolvedAddressableDevice(from: device)
        }

        let playbackDevice = try await apiClient.currentPlaybackState()?.device
        if let device = PlaybackCoordinator.preferredCurrentDevice(playbackDevice) {
            AppLogger.shared.log("using current playback device because devices endpoint omitted the Mac", category: "playback")
            return try resolvedAddressableDevice(from: device)
        }

        if devices.isEmpty, playbackDevice == nil {
            AppLogger.shared.log("Spotify device discovery returned no devices or playback state", category: "playback")
            return nil
        }

        let summary = devices.map {
            "type=\($0.type),active=\($0.isActive),restricted=\($0.isRestricted),hasID=\($0.id?.isEmpty == false)"
        }.joined(separator: ";")
        AppLogger.shared.log("no addressable Mac device count=\(devices.count) devices=[\(summary)]", category: "playback")
        throw SpotifyAPIError.noDevice
    }

    private func resolvedAddressableDevice(from device: SpotifyDevice?) throws -> AddressableSpotifyDevice {
        guard let device else {
            throw SpotifyAPIError.noDevice
        }
        guard !device.isRestricted else {
            throw SpotifyAPIError.restrictedDevice
        }
        guard let id = device.id, !id.isEmpty else {
            throw SpotifyAPIError.noDevice
        }
        return AddressableSpotifyDevice(
            id: id,
            isActive: device.isActive
        )
    }

    static func preferredDevice(from devices: [SpotifyDevice]) -> SpotifyDevice? {
        let addressableDevices = devices.filter { ($0.id?.isEmpty == false) }

        if let activeComputer = addressableDevices.first(where: { $0.type == "Computer" && $0.isActive }) {
            return activeComputer
        }

        if !localComputerName.isEmpty,
           let namedComputer = addressableDevices.first(where: { $0.type == "Computer" && $0.name.localizedCaseInsensitiveContains(localComputerName) }) {
            return namedComputer
        }

        return addressableDevices.first(where: { $0.type == "Computer" })
    }

    private static func preferredCurrentDevice(_ device: SpotifyDevice?) -> SpotifyDevice? {
        guard let device,
              device.type == "Computer",
              device.id?.isEmpty == false
        else {
            return nil
        }
        return device
    }
}

struct AddressableSpotifyDevice: Equatable {
    let id: String
    let isActive: Bool
}

private extension SpotifyAPIError {
    /// Errors that mean "this specific request was rejected", not "playback can't work at all".
    var allowsPlaybackFallback: Bool {
        switch self {
        case .notFound, .noDevice, .message, .playbackControlUnavailable, .invalidResponse:
            return true
        case .missingConfiguration, .unauthorized, .insufficientScope, .restrictedDevice,
             .premiumRequired, .rateLimited:
            return false
        }
    }
}
