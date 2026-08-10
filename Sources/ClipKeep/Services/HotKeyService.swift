import AppKit
import Carbon
import Foundation

/// Registers a system-wide Carbon hotkey to toggle the ClipKeep panel.
@MainActor
final class HotKeyService {
    static let shared = HotKeyService()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onFire: (() -> Void)?

    private let hotKeyID = EventHotKeyID(signature: OSType(0x434B4854), id: 1) // 'CKHT'

    private init() {}

    func update(from settings: AppSettings, onFire: @escaping () -> Void) {
        self.onFire = onFire
        unregister()
        guard settings.globalHotkeyEnabled else { return }
        register(
            keyCode: UInt32(settings.globalHotkeyKeyCode),
            modifiers: carbonModifiers(from: settings.globalHotkeyModifiers)
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData else { return noErr }
                let service = Unmanaged<HotKeyService>.fromOpaque(userData).takeUnretainedValue()
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if hkID.signature == service.hotKeyID.signature, hkID.id == service.hotKeyID.id {
                    DispatchQueue.main.async {
                        service.onFire?()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &handlerRef
        )

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            NSLog("ClipKeep: failed to register hotkey (status \(status))")
        }
    }

    private func carbonModifiers(from nsModifiersRaw: Int) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(nsModifiersRaw))
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    /// Human-readable shortcut, e.g. "⌘⇧V".
    static func displayString(keyCode: Int, modifiers: Int) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers)).intersection(.deviceIndependentFlagsMask)
        var parts = ""
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option) { parts += "⌥" }
        if flags.contains(.shift) { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }
        parts += keyCodeToGlyph(keyCode)
        return parts
    }

    private static func keyCodeToGlyph(_ keyCode: Int) -> String {
        // Common ANSI key codes
        let map: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M", 18: "1", 19: "2", 20: "3",
            21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return map[keyCode] ?? "Key\(keyCode)"
    }
}
