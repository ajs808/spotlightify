import AppKit

@MainActor
final class StatusBarController: NSObject {
    private let environment: AppEnvironment
    nonisolated static let maxTitleLength = 32

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init()
    }

    func install() {
        guard let button = statusItem.button else {
            return
        }

        if let logoImage = NSImage(named: "MenuBarIcon") {
            logoImage.isTemplate = true
            logoImage.size = NSSize(width: 18, height: 18)
            button.image = logoImage
            button.imagePosition = .imageOnly
            button.title = ""
        } else if let symbolImage = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: "Spotlightify"
        ) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            let image = symbolImage.withSymbolConfiguration(configuration) ?? symbolImage
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            button.image = nil
            button.title = "♪"
        }

        button.toolTip = "Spotlightify"
        refresh()
    }

    func refresh() {
        refreshButtonTitle()
        refreshMenu()
    }

    /// "Song — Artist", shortened to keep the menu bar tidy; nil when nothing should show.
    nonisolated static func menuBarTitle(for nowPlaying: MenuBarNowPlaying?, maxLength: Int = maxTitleLength) -> String? {
        guard let nowPlaying, nowPlaying.isPlaying, !nowPlaying.title.isEmpty else { return nil }
        let full = nowPlaying.artist.isEmpty ? nowPlaying.title : "\(nowPlaying.title) — \(nowPlaying.artist)"
        guard full.count > maxLength else { return full }
        return String(full.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private func refreshButtonTitle() {
        guard let button = statusItem.button, button.image != nil else { return }

        let title = environment.showsNowPlayingInMenuBar
            ? Self.menuBarTitle(for: environment.menuBarNowPlaying)
            : nil
        if let title {
            button.title = " " + title
            button.imagePosition = .imageLeading
            button.font = NSFont.menuBarFont(ofSize: 0)
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
        button.toolTip = environment.menuBarNowPlaying.map { "\($0.title) — \($0.artist)" } ?? "Spotlightify"
    }

    private func refreshMenu() {
        let menu = NSMenu()
        if let nowPlaying = environment.menuBarNowPlaying {
            let header = NSMenuItem(title: nowPlaying.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            let detail = [nowPlaying.artist, nowPlaying.isPlaying ? "" : "Paused"]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            if !detail.isEmpty {
                if #available(macOS 14.4, *) {
                    header.subtitle = detail
                } else {
                    header.title = "\(nowPlaying.title) — \(detail)"
                }
            }
            header.image = NSImage(
                systemSymbolName: nowPlaying.isPlaying ? "play.fill" : "pause.fill",
                accessibilityDescription: nowPlaying.isPlaying ? "Playing" : "Paused"
            )
            menu.addItem(header)
            menu.addItem(.separator())
        }
        menu.addItem(makeItem(title: "Open Search", action: #selector(openSearch)))
        menu.addItem(makeItem(title: "Spotify Setup", action: #selector(openSetup)))
        menu.addItem(makeItem(title: "Login / Reconnect", action: #selector(loginReconnect)))
        menu.addItem(makeItem(title: "Sign Out", action: #selector(signOut)))
        menu.addItem(makeItem(title: "Open Spotify", action: #selector(openSpotify)))
        menu.addItem(.separator())
        menu.addItem(makeItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            state: environment.launchAtLoginEnabled ? .on : .off
        ))
        menu.addItem(makeItem(
            title: "Show Song in Menu Bar",
            action: #selector(toggleShowsNowPlaying),
            state: environment.showsNowPlayingInMenuBar ? .on : .off
        ))
        let localControlsItem = makeItem(
            title: "Use Local Spotify Controls",
            action: #selector(toggleUsesLocalControls),
            state: environment.usesLocalControls ? .on : .off
        )
        localControlsItem.toolTip = "Faster, but only controls Spotify on this Mac. Turn off to control phones and speakers."
        menu.addItem(localControlsItem)
        menu.addItem(makeAppearanceItem())
        if environment.canUseSparkleUpdater {
            menu.addItem(.separator())
            menu.addItem(makeItem(title: "Check for Updates…", action: #selector(checkForUpdates)))
        }
        menu.addItem(.separator())
        menu.addItem(makeItem(title: "Quit Spotlightify", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func makeAppearanceItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Appearance")

        submenu.addItem(makeItem(
            title: AppearancePreference.light.title,
            action: #selector(useLightAppearance),
            state: appearanceState(for: .light)
        ))
        submenu.addItem(makeItem(
            title: AppearancePreference.dark.title,
            action: #selector(useDarkAppearance),
            state: appearanceState(for: .dark)
        ))
        submenu.addItem(makeItem(
            title: AppearancePreference.system.title,
            action: #selector(useSystemAppearance),
            state: appearanceState(for: .system)
        ))

        item.submenu = submenu
        return item
    }

    private func appearanceState(for preference: AppearancePreference) -> NSControl.StateValue {
        environment.appearanceStore.preference == preference ? .on : .off
    }

    private func makeItem(
        title: String,
        action: Selector,
        keyEquivalent: String = "",
        state: NSControl.StateValue = .off
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.state = state
        return item
    }

    @objc private func openSearch() {
        environment.togglePanel()
    }

    @objc private func loginReconnect() {
        environment.loginReconnect()
    }

    @objc private func openSetup() {
        environment.openSetup()
    }

    @objc private func signOut() {
        environment.signOut()
    }

    @objc private func openSpotify() {
        environment.openSpotify()
    }

    @objc private func toggleLaunchAtLogin() {
        environment.toggleLaunchAtLogin()
    }

    @objc private func toggleUsesLocalControls() {
        environment.setUsesLocalControls(!environment.usesLocalControls)
    }

    @objc private func toggleShowsNowPlaying() {
        environment.setShowsNowPlayingInMenuBar(!environment.showsNowPlayingInMenuBar)
    }

    @objc private func useSystemAppearance() {
        environment.setAppearance(.system)
    }

    @objc private func useLightAppearance() {
        environment.setAppearance(.light)
    }

    @objc private func useDarkAppearance() {
        environment.setAppearance(.dark)
    }

    @objc private func checkForUpdates() {
        environment.checkForUpdates()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
