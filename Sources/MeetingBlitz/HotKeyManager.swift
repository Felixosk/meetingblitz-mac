import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys (Runde 44, seit F5 mehrere). The menu-bar icon only
/// appears on the currently active display's menu bar and gets swallowed behind
/// the MacBook notch, macOS can't mirror one NSStatusItem onto both menu bars. A
/// global hotkey sidesteps that entirely: it works no matter which screen is
/// active or how crowded the menu bar is.
///
/// Uses Carbon's RegisterEventHotKey, which needs NO Accessibility permission
/// (unlike a CGEventTap) and works fine for an accessory app. The C event
/// handler can't capture Swift context, so `self` rides in via userData; hotkey
/// events are delivered on the main thread, so the MainActor hop is sound. Which
/// hotkey fired is read from the event's own EventHotKeyID — with more than one
/// registered, a single shared handler would otherwise fire the wrong action.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    /// What a hotkey does. The raw value doubles as the Carbon hotkey id.
    enum Action: UInt32, CaseIterable {
        case showWidget = 1
        case joinNext = 2
    }

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?

    /// (Re)register one hotkey. `keyCode` is a kVK_* virtual key, `modifiers` a
    /// Carbon mask (controlKey/optionKey/cmdKey/shiftKey). Returns false when
    /// the combination is taken — Carbon reports that instead of stealing it,
    /// and a silently dead shortcut is the worst outcome.
    @discardableResult
    func register(_ action: Action, keyCode: UInt32, modifiers: UInt32,
                  handler: @escaping () -> Void) -> Bool {
        unregister(action)
        installHandlerIfNeeded()
        actions[action.rawValue] = handler

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4D424C5A) /* 'MBLZ' */, id: action.rawValue)
        let status = RegisterEventHotKey(keyCode, modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            actions[action.rawValue] = nil
            return false
        }
        refs[action.rawValue] = ref
        return true
    }

    func unregister(_ action: Action) {
        if let ref = refs.removeValue(forKey: action.rawValue) { UnregisterEventHotKey(ref) }
        actions[action.rawValue] = nil
    }

    func unregisterAll() {
        for a in Action.allCases { unregister(a) }
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            // Which one fired? Without this every hotkey would run the action
            // that happened to be registered last.
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { mgr.actions[hkID.id]?() }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
    }

    // MARK: - Defaults

    static let defaultKeyCode = UInt32(kVK_ANSI_M)
    static let defaultModifiers = UInt32(controlKey | optionKey)
    static let defaultLabel = "⌃⌥M"
    static let defaultJoinKeyCode = UInt32(kVK_ANSI_J)
    static let defaultJoinModifiers = UInt32(controlKey | optionKey)
    static let defaultJoinLabel = "⌃⌥J"

    /// Translate an NSEvent's modifiers into the Carbon mask Carbon wants.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }

    /// Human label like "⌃⌥M" for the settings row. The key's own character
    /// comes from the recorded event, so no virtual-keycode table is needed.
    static func label(modifiers flags: NSEvent.ModifierFlags, key: String) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key.uppercased()
    }
}
