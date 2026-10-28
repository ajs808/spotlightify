import AppKit
import Carbon
import Foundation

struct HotKeyShortcut {
    enum Identifier: UInt32 {
        case togglePanel = 1
        case playPause = 2
        case nextTrack = 3
        case previousTrack = 4
        case seekBackward = 5
        case seekForward = 6
    }

    let id: Identifier
    let key: UInt32
    let modifiers: NSEvent.ModifierFlags
}

@MainActor
final class HotKeyManager {
    private final class HandlerBox {
        let action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }
    }

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var handlers: [UInt32: HandlerBox] = [:]
    private var eventHandlerRef: EventHandlerRef?

    init() {
        installHandlerIfNeeded()
    }

    func registerShortcut(_ shortcut: HotKeyShortcut, action: @escaping () -> Void) {
        var hotKeyRef: EventHotKeyRef?
        let signature = UTGetOSTypeFromString("SPTY" as CFString)
        let hotKeyID = EventHotKeyID(signature: signature, id: shortcut.id.rawValue)
        let status = RegisterEventHotKey(
            shortcut.key,
            shortcut.modifiers.carbonFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else {
            AppLogger.shared.log(
                "failed to register hotkey id=\(shortcut.id.rawValue) key=\(shortcut.key) modifiers=\(shortcut.modifiers.rawValue) status=\(status)",
                category: "hotkey"
            )
            return
        }

        hotKeyRefs.append(hotKeyRef)
        handlers[shortcut.id.rawValue] = HandlerBox(action: action)
        AppLogger.shared.log(
            "registered hotkey id=\(shortcut.id.rawValue) key=\(shortcut.key) modifiers=\(shortcut.modifiers.rawValue)",
            category: "hotkey"
        )
    }

    func unregisterAll() {
        hotKeyRefs.forEach { hotKeyRef in
            if let hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
            }
        }
        hotKeyRefs.removeAll()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else { return noErr }

                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                AppLogger.shared.log("hotkey fired id=\(hotKeyID.id)", category: "hotkey")
                manager.handlers[hotKeyID.id]?.action()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }
}

private extension NSEvent.ModifierFlags {
    var carbonFlags: UInt32 {
        var flags: UInt32 = 0

        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        if contains(.control) { flags |= UInt32(controlKey) }

        return flags
    }
}
