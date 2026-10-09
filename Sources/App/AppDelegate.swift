import AppKit
import Carbon
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment!
    private var panelController: SearchPanelController!
    private var statusBarController: StatusBarController!
    private var hotKeyManager: HotKeyManager!
    private var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSSetUncaughtExceptionHandler { exception in
            AppLogger.shared.log(
                "Uncaught exception: \(exception.name.rawValue) reason=\(exception.reason ?? "nil") stack=\(exception.callStackSymbols.joined(separator: " | "))",
                category: "crash"
            )
        }

        NSApp.setActivationPolicy(.accessory)

        // Unit tests run inside the app; skip startup so they never touch the real
        // keychain login, Spotify, global hotkeys or the menu bar.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        AppLogger.shared.log("applicationDidFinishLaunching", category: "app")

        environment = AppEnvironment()
        panelController = SearchPanelController(environment: environment)
        statusBarController = StatusBarController(environment: environment)
        hotKeyManager = HotKeyManager()

        if ApplicationInstallLocation.canUseSparkleUpdater {
            let controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            controller.updater.automaticallyChecksForUpdates = true
            updaterController = controller
        }

        environment.bind(panelController: panelController, statusBarController: statusBarController)
        environment.updaterController = updaterController
        statusBarController.install()
        environment.start()
        registerHotKeys()
        environment.configureLaunchAtLogin()
        AppLogger.shared.log("app launch completed", category: "app")
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.shared.log("applicationWillTerminate", category: "app")
        hotKeyManager?.unregisterAll()
        environment?.playerMonitor.stop()
    }

    private func registerHotKeys() {
        hotKeyManager.registerShortcut(
            HotKeyShortcut(
                id: .togglePanel,
                key: UInt32(kVK_Space),
                modifiers: [.command, .shift]
            )
        ) { [weak self] in
            Task { @MainActor in
                self?.environment.togglePanel()
            }
        }

        hotKeyManager.registerShortcut(
            HotKeyShortcut(
                id: .playPause,
                key: UInt32(kVK_ANSI_P),
                modifiers: [.control, .option]
            )
        ) { [weak self] in
            Task { @MainActor in
                self?.environment.playPause()
            }
        }

        hotKeyManager.registerShortcut(
            HotKeyShortcut(
                id: .nextTrack,
                key: UInt32(kVK_ANSI_N),
                modifiers: [.control, .option]
            )
        ) { [weak self] in
            Task { @MainActor in
                self?.environment.nextTrack()
            }
        }

        hotKeyManager.registerShortcut(
            HotKeyShortcut(
                id: .previousTrack,
                key: UInt32(kVK_ANSI_B),
                modifiers: [.control, .option]
            )
        ) { [weak self] in
            Task { @MainActor in
                self?.environment.previousTrack()
            }
        }
    }
}
