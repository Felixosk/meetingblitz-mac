import AppKit
import Carbon.HIToolbox

/// A single system-wide hotkey (Runde 44). the menu-bar icon only appears on
/// the currently active display's menu bar and gets swallowed behind the
/// MacBook notch, macOS can't mirror one NSStatusItem onto both menu bars. A
/// global hotkey sidesteps that entirely: it opens the widget no matter which
/// screen is active or how crowded the menu bar is.
///
/// Uses Carbon's RegisterEventHotKey, which needs NO Accessibility permission
/// (unlike a CGEventTap) and works fine for an accessory app. The C event
/// handler can't capture Swift context, so `self` rides in via userData; hotkey
/// events are delivered on the main thread, so the MainActor hop is sound.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    /// (Re)register the hotkey. `keyCode` is a kVK_* virtual key, `modifiers` a
    /// Carbon mask (controlKey/optionKey/cmdKey/shiftKey).
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        unregister()
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { mgr.action?() }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x4D424C5A) /* 'MBLZ' */, id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
        action = nil
    }

    /// The fixed default: ⌃⌥M (Control-Option-M). Human label for the settings UI.
    static let defaultKeyCode = UInt32(kVK_ANSI_M)
    static let defaultModifiers = UInt32(controlKey | optionKey)
    static let defaultLabel = "⌃⌥M"
}
