import AppKit
import Foundation
import Sparkle

/// What the menu bar shows next to the icon.
struct MenuBarNowPlaying: Equatable {
    let title: String
    let artist: String
    let isPlaying: Bool
}

@MainActor
final class AppEnvironment: ObservableObject {
    private static let showsNowPlayingInMenuBarKey = "menuBar.showsNowPlaying"
    private static let usesLocalControlsKey = "playback.usesLocalControls"

    @Published var launchAtLoginEnabled = false
    @Published private(set) var menuBarNowPlaying: MenuBarNowPlaying?
    @Published private(set) var showsNowPlayingInMenuBar: Bool
    /// Control the Spotify app on this Mac directly. Faster, but can't reach other Spotify Connect devices.
    @Published private(set) var usesLocalControls: Bool

    let appearanceStore: AppearancePreferenceStore
    let configuration: AppConfiguration
    let clientConfigurationStore: ClientConfigurationStore
    let authManager: SpotifyAuthManager
    let apiClient: SpotifyAPIClient
    let playbackCoordinator: PlaybackCoordinator
    let launchAtLoginManager = LaunchAtLoginManager()
    let searchViewModel: SearchViewModel
    let playerMonitor = SpotifyPlayerMonitor()
    private let appleScriptTransport = AppleScriptTransportController()
    var updaterController: SPUStandardUpdaterController?

    var canUseSparkleUpdater: Bool {
        ApplicationInstallLocation.canUseSparkleUpdater
    }

    var isPlaybackRequestInProgress: Bool {
        playbackRequestCount > 0
    }

    private let defaults: UserDefaults
    private weak var panelController: SearchPanelController?
    private weak var statusBarController: StatusBarController?
    private var playbackRequestCount = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsNowPlayingInMenuBar = defaults.object(forKey: Self.showsNowPlayingInMenuBarKey) as? Bool ?? true
        usesLocalControls = defaults.object(forKey: Self.usesLocalControlsKey) as? Bool ?? true
        appearanceStore = AppearancePreferenceStore()
        let configuration = AppConfiguration.load()
        let clientConfigurationStore = ClientConfigurationStore(bundledClientID: configuration.bundledSpotifyClientID)
        self.configuration = configuration
        self.clientConfigurationStore = clientConfigurationStore
        AppLogger.shared.configure(logFileURL: configuration.logFileURL)
        AppLogger.shared.log("appSupportDirectory=\(configuration.appSupportDirectory.path)", category: "app")
        AppLogger.shared.log("logFile=\(configuration.logFileURL.path)", category: "app")
        let keychain = KeychainStore(service: "app.spotlightify")
        authManager = SpotifyAuthManager(
            configuration: configuration,
            keychain: keychain,
            clientIDProvider: { [clientConfigurationStore] in
                clientConfigurationStore.currentClientID()
            }
        )
        apiClient = SpotifyAPIClient(authManager: authManager)
        playbackCoordinator = PlaybackCoordinator(apiClient: apiClient)
        searchViewModel = SearchViewModel(apiClient: apiClient, redirectURI: configuration.redirectURI)

        authManager.onAuthorizationSucceeded = { [weak self] in
            AppLogger.shared.log("authorization success callback", category: "auth")
            NSApp.activate(ignoringOtherApps: true)
            self?.searchViewModel.resetLibraryAccess()
            self?.searchViewModel.prepareForPresentation()
            self?.panelController?.show()
            self?.searchViewModel.retrySearchIfNeeded()
        }

        searchViewModel.onPlayRequested = { [weak self] target, label in
            await self?.play(target, label: label)
        }
        searchViewModel.onQueueRequested = { [weak self] uris, label in
            await self?.queue(uris, label: label)
        }
        searchViewModel.onNowPlayingChanged = { [weak self] summary in
            self?.updateMenuBarNowPlaying(summary.map {
                MenuBarNowPlaying(title: $0.title, artist: $0.artistLine, isPlaying: $0.isPlaying)
            })
        }
        searchViewModel.localNowPlaying = { [weak self] in
            guard let self, self.usesLocalControls, self.isSpotifyRunning else { return nil }
            return self.appleScriptTransport.nowPlaying()
        }
        searchViewModel.onSeekRequested = { [weak self] positionMS in
            await self?.seek(to: positionMS)
        }
        searchViewModel.onLoginRequested = { [weak self] in
            self?.loginReconnect()
        }
        searchViewModel.isSpotifyConfigured = { [weak self] in
            self?.clientConfigurationStore.hasConfiguredClientID ?? false
        }
        searchViewModel.currentConfiguredClientID = { [weak self] in
            self?.clientConfigurationStore.currentClientID() ?? ""
        }
        searchViewModel.hasSavedClientID = clientConfigurationStore.hasUserConfiguredClientID
        searchViewModel.onSaveClientIDRequested = { [weak self] clientID in
            self?.saveClientID(clientID)
        }
        searchViewModel.onClearConfigurationRequested = { [weak self] in
            self?.clearSpotifyConfiguration()
        }
        searchViewModel.onOpenSpotifyRequested = { [weak self] in
            self?.openSpotify()
        }

        playerMonitor.onEvent = { [weak self] event in
            self?.handlePlayerEvent(event)
        }
        playerMonitor.onSpotifyQuit = { [weak self] in
            self?.updateMenuBarNowPlaying(nil)
        }
    }

    /// Starts listening to Spotify and seeds the menu bar with what's already playing.
    func start() {
        playerMonitor.start()
        guard clientConfigurationStore.hasConfiguredClientID else { return }
        Task {
            // Never trigger an interactive login just to fill the menu bar.
            guard await apiClient.authorizationStateForSearch() == .ready else { return }
            searchViewModel.refreshNowPlaying()
        }
    }

    func setUsesLocalControls(_ usesLocal: Bool) {
        usesLocalControls = usesLocal
        defaults.set(usesLocal, forKey: Self.usesLocalControlsKey)
        statusBarController?.refresh()
        searchViewModel.refreshNowPlaying()
    }

    func setShowsNowPlayingInMenuBar(_ shows: Bool) {
        showsNowPlayingInMenuBar = shows
        defaults.set(shows, forKey: Self.showsNowPlayingInMenuBarKey)
        statusBarController?.refresh()
    }

    func bind(panelController: SearchPanelController, statusBarController: StatusBarController) {
        self.panelController = panelController
        self.statusBarController = statusBarController
    }

    func configureLaunchAtLogin() {
        AppLogger.shared.log("configureLaunchAtLogin", category: "app")

        if ApplicationInstallLocation.needsInstallToApplicationsFolder {
            if launchAtLoginManager.currentStatus {
                try? launchAtLoginManager.setEnabled(false)
            }
            launchAtLoginEnabled = false
            statusBarController?.refresh()
            return
        }

        launchAtLoginEnabled = launchAtLoginManager.currentStatus
        statusBarController?.refresh()
    }

    func togglePanel() {
        AppLogger.shared.log("togglePanel visible=\(panelController?.isVisible == true)", category: "panel")
        panelController?.toggle()
        if panelController?.isVisible == true {
            searchViewModel.prepareForPresentation()
            panelController?.focusSearchField()
        }
    }

    func closePanel() {
        AppLogger.shared.log("closePanel", category: "panel")
        panelController?.close()
    }

    func focusSearchField() {
        panelController?.focusSearchField()
    }

    func openSetup() {
        searchViewModel.presentSetup(
            clientID: clientConfigurationStore.currentClientID(),
            hasSavedClientID: clientConfigurationStore.hasUserConfiguredClientID
        )
        panelController?.show()
    }

    func playPause() {
        if runLocally("playPause", appleScriptTransport.playPause) { return }
        runTransportCommand("playPause") { try await $0.playPause() }
    }

    func nextTrack() {
        if runLocally("nextTrack", appleScriptTransport.nextTrack) { return }
        runTransportCommand("nextTrack") { try await $0.nextTrack() }
    }

    func previousTrack() {
        if runLocally("previousTrack", appleScriptTransport.previousTrack) { return }
        runTransportCommand("previousTrack") { try await $0.previousTrack() }
    }

    func seek(by offsetSeconds: Double) {
        AppLogger.shared.log("seek by offsetSeconds=\(offsetSeconds) requested", category: "transport")
        guard usesLocalControls else {
            searchViewModel.requestSeek(by: Int(offsetSeconds * 1_000))
            return
        }
        // Launching Spotify just to seek makes no sense, so local mode has no Web API fallback here.
        guard isSpotifyRunning, let positionSeconds = appleScriptTransport.seek(by: offsetSeconds) else { return }
        searchViewModel.applyPlaybackPosition(Int((positionSeconds * 1_000).rounded()))
    }

    /// Runs a command against the local Spotify app, which skips the Web API's round trip and lag.
    /// Returns false when local controls are off, Spotify isn't running, or it refused, so the caller
    /// can fall back to the Web API.
    private func runLocally(_ name: String, _ command: () -> Bool) -> Bool {
        guard usesLocalControls, isSpotifyRunning else { return false }
        guard command() else {
            AppLogger.shared.log("\(name) failed locally; using Web API", category: "transport")
            return false
        }
        AppLogger.shared.log("\(name) handled locally", category: "transport")
        return true
    }

    private func runTransportCommand(
        _ name: String,
        _ command: @escaping @Sendable (PlaybackCoordinator) async throws -> Void
    ) {
        guard clientConfigurationStore.hasConfiguredClientID else {
            openSetup()
            searchViewModel.setInlineMessage("Add your Spotify Client ID before using transport controls.")
            return
        }
        Task {
            AppLogger.shared.log("\(name) requested", category: "transport")
            do {
                try await command(playbackCoordinator)
                AppLogger.shared.log("\(name) succeeded", category: "transport")
                searchViewModel.refreshNowPlaying()
            } catch {
                AppLogger.shared.log("\(name) failed error=\(error.localizedDescription)", category: "transport")
                searchViewModel.setInlineMessage(error.localizedDescription)
                panelController?.show()
            }
        }
    }

    func loginReconnect() {
        guard clientConfigurationStore.hasConfiguredClientID else {
            openSetup()
            searchViewModel.setInlineMessage("Enter your Spotify Client ID before signing in.")
            return
        }
        guard !searchViewModel.loginInProgress else { return }
        searchViewModel.setLoginInProgress(true)

        Task {
            AppLogger.shared.log("loginReconnect started", category: "auth")
            do {
                _ = try await authManager.ensureAuthorized(forceReauthentication: true)
                AppLogger.shared.log("loginReconnect succeeded", category: "auth")
                searchViewModel.resetLibraryAccess()
                searchViewModel.setInlineMessage("Spotify connected.", isError: false)
                searchViewModel.prepareForPresentation()
                panelController?.show()
            } catch {
                AppLogger.shared.log("loginReconnect failed: \(error.localizedDescription)", category: "auth")
                searchViewModel.setInlineMessage(error.localizedDescription)
                panelController?.show()
            }

            searchViewModel.setLoginInProgress(false)

            if case .authenticationRequired = searchViewModel.panelState {
                if searchViewModel.inlineMessage == nil {
                    searchViewModel.setInlineMessage("Spotify login did not complete.")
                }
            }
        }
    }

    func openSpotify() {
        if let spotifyURL = URL(string: "spotify:") {
            NSWorkspace.shared.open(spotifyURL)
        }
    }

    func checkForUpdates() {
        guard canUseSparkleUpdater, let updaterController else {
            return
        }
        AppLogger.shared.log("checkForUpdates requested", category: "app")
        updaterController.checkForUpdates(nil)
    }

    func toggleLaunchAtLogin() {
        guard !ApplicationInstallLocation.needsInstallToApplicationsFolder else {
            return
        }

        do {
            try launchAtLoginManager.setEnabled(!launchAtLoginEnabled)
            launchAtLoginEnabled = launchAtLoginManager.currentStatus
            statusBarController?.refresh()
        } catch {
            searchViewModel.setInlineMessage(error.localizedDescription)
        }
    }

    func setAppearance(_ preference: AppearancePreference) {
        appearanceStore.setPreference(preference)
        panelController?.applyAppearance(preference)
        statusBarController?.refresh()
        AppLogger.shared.log("appearance changed to \(preference.rawValue)", category: "appearance")
    }

    func signOut() {
        do {
            try authManager.clearStoredAuthorization()
            Task { await playbackCoordinator.forgetCachedDevice() }
            searchViewModel.clearNowPlaying()
            searchViewModel.resetLibraryAccess()
            searchViewModel.setInlineMessage("Spotify login cleared.", isError: false)
            searchViewModel.prepareForPresentation()
        } catch {
            searchViewModel.setInlineMessage(error.localizedDescription)
        }
    }

    private func play(_ target: PlaybackTarget, label: String) async {
        guard !isPlaybackRequestInProgress else {
            AppLogger.shared.log("play ignored because another playback request is in progress", category: "playback")
            return
        }

        if runLocally("play", { appleScriptTransport.play(target) }) {
            searchViewModel.setInlineMessage("Playing \(label)", isError: false)
            searchViewModel.refreshQueueAfterPlaybackChange()
            searchViewModel.clearQuery()
            closePanel()
            return
        }

        playbackRequestCount += 1
        defer { playbackRequestCount -= 1 }

        do {
            AppLogger.shared.log("play requested target=\(target)", category: "playback")
            _ = try await authManager.ensureAuthorized()
            try await performWithAutoLaunch { try await playbackCoordinator.play(target) }
            AppLogger.shared.log("play succeeded", category: "playback")
            searchViewModel.setInlineMessage("Playing \(label)", isError: false)
            searchViewModel.refreshNowPlaying()
            searchViewModel.refreshQueueAfterPlaybackChange()
            searchViewModel.clearQuery()
            closePanel()
        } catch {
            AppLogger.shared.log("play failed error=\(error.localizedDescription)", category: "playback")
            searchViewModel.setInlineMessage(error.localizedDescription)
            panelController?.show()
            focusSearchField()
        }
    }

    private func queue(_ uris: [String], label: String) async {
        playbackRequestCount += 1
        defer { playbackRequestCount -= 1 }

        do {
            AppLogger.shared.log("queue requested count=\(uris.count)", category: "playback")
            _ = try await authManager.ensureAuthorized()
            try await performWithAutoLaunch { try await playbackCoordinator.queue(trackURIs: uris) }
            AppLogger.shared.log("queue succeeded count=\(uris.count)", category: "playback")
            let suffix = uris.count > 1 ? " (\(uris.count) tracks)" : ""
            searchViewModel.showTransientMessage("Queued \(label)\(suffix)")
            searchViewModel.refreshNowPlaying()
            searchViewModel.refreshQueueAfterPlaybackChange()
            searchViewModel.clearQuery()
        } catch {
            AppLogger.shared.log("queue failed count=\(uris.count) error=\(error.localizedDescription)", category: "playback")
            searchViewModel.setInlineMessage(error.localizedDescription)
            panelController?.show()
            focusSearchField()
        }
    }

    private func seek(to positionMS: Int) async {
        if runLocally("seek", { appleScriptTransport.seek(to: Double(positionMS) / 1_000) }) { return }

        playbackRequestCount += 1
        defer { playbackRequestCount -= 1 }

        do {
            AppLogger.shared.log("seek requested positionMS=\(positionMS)", category: "playback")
            _ = try await authManager.ensureAuthorized()
            try await performWithAutoLaunch { try await playbackCoordinator.seek(to: positionMS) }
            AppLogger.shared.log("seek succeeded positionMS=\(positionMS)", category: "playback")
        } catch {
            AppLogger.shared.log("seek failed positionMS=\(positionMS) error=\(error.localizedDescription)", category: "playback")
            searchViewModel.setInlineMessage(error.localizedDescription)
            panelController?.show()
        }
    }

    private func saveClientID(_ clientID: String) {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchViewModel.setInlineMessage("Paste your Spotify Client ID first.")
            searchViewModel.presentSetup(clientID: trimmed, hasSavedClientID: clientConfigurationStore.hasUserConfiguredClientID)
            return
        }

        do {
            try clientConfigurationStore.saveClientID(trimmed)
            try authManager.clearStoredAuthorization()
            searchViewModel.hasSavedClientID = clientConfigurationStore.hasUserConfiguredClientID
            searchViewModel.setInlineMessage("Client ID saved. Connect Spotify.", isError: false)
            searchViewModel.prepareForPresentation()
            panelController?.show()
        } catch {
            searchViewModel.setInlineMessage(error.localizedDescription)
            searchViewModel.presentSetup(clientID: trimmed, hasSavedClientID: clientConfigurationStore.hasUserConfiguredClientID)
        }
    }

    private func clearSpotifyConfiguration() {
        do {
            try clientConfigurationStore.clearClientID()
            try authManager.clearStoredAuthorization()
            searchViewModel.hasSavedClientID = false
            searchViewModel.clearNowPlaying()
            searchViewModel.setInlineMessage("Saved Spotify setup cleared.", isError: false)
            searchViewModel.presentSetup(clientID: "", hasSavedClientID: false)
            panelController?.show()
        } catch {
            searchViewModel.setInlineMessage(error.localizedDescription)
        }
    }

    private func handlePlayerEvent(_ event: SpotifyPlayerEvent) {
        switch event.state {
        case .stopped:
            updateMenuBarNowPlaying(nil)
        case .playing, .paused:
            if let title = event.title, !title.isEmpty {
                updateMenuBarNowPlaying(MenuBarNowPlaying(
                    title: title,
                    artist: event.artist ?? "",
                    isPlaying: event.state == .playing
                ))
            }
        }
        searchViewModel.applyPlayerEvent(event)
    }

    private func updateMenuBarNowPlaying(_ nowPlaying: MenuBarNowPlaying?) {
        guard menuBarNowPlaying != nowPlaying else { return }
        menuBarNowPlaying = nowPlaying
        statusBarController?.refresh()
    }

    private func performWithAutoLaunch(_ operation: () async throws -> Void) async throws {
        do {
            try await operation()
        } catch let error as SpotifyAPIError where error == .noDevice {
            let spotifyWasRunning = isSpotifyRunning
            AppLogger.shared.log("no device found spotifyRunning=\(spotifyWasRunning)", category: "playback")

            if spotifyWasRunning {
                searchViewModel.setInlineMessage(
                    "Spotify is reconnecting its playback device…",
                    isError: false,
                    isLoading: true
                )
            } else {
                searchViewModel.setInlineMessage(
                    "Opening Spotify and waiting for playback…",
                    isError: false,
                    isLoading: true
                )
            }
            // Sending a non-activating reopen event also wakes an already-running
            // Spotify client whose Connect device has fallen off the Web API.
            launchSpotifyInBackground()

            // Retry the actual command so transient device-list and playback-state
            // inconsistencies recover without activating Spotify or losing panel focus.
            for attempt in 1...20 {
                try await Task.sleep(for: .milliseconds(500))
                do {
                    try await operation()
                    AppLogger.shared.log("Spotify playback command recovered attempt=\(attempt)", category: "playback")
                    return
                } catch let retryError as SpotifyAPIError where retryError == .noDevice {
                    continue
                }
            }
            if spotifyWasRunning {
                throw SpotifyAPIError.message("Spotify is open but hasn’t exposed a playback device yet.")
            }
            throw SpotifyAPIError.noDevice
        }
    }

    private var isSpotifyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty
    }

    private func launchSpotifyInBackground() {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else {
            AppLogger.shared.log("Spotify application URL unavailable; using URL scheme", category: "playback")
            openSpotify()
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { @Sendable application, error in
            if let error {
                AppLogger.shared.log("background Spotify launch failed error=\(error.localizedDescription)", category: "playback")
            } else {
                AppLogger.shared.log("background Spotify launch requested running=\(application != nil)", category: "playback")
            }
        }
    }
}
