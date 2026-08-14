import Foundation

/// Best-effort "is my screen being shared right now" check (Runde 5).
///
/// macOS only publishes its OWN screen sharing state (Screen Sharing.app /
/// Remote Management / classroom-style observation) via the session dictionary
/// key `CGSSessionScreenIsShared`. Third-party conferencing screen shares
/// (Zoom, Google Meet, Teams) are NOT exposed by the OS, so those are covered
/// by the manual Ruhe-Modus toggle instead.
///
/// `CGSessionCopyCurrentDictionaryOfProperties` isn't in the command-line-tools
/// CoreGraphics module map, so we resolve it dynamically via dlsym, it's a
/// stable public CoreGraphics symbol, this just avoids the missing header.
enum ScreenShareDetector {
    private typealias CopyFn = @convention(c) () -> Unmanaged<CFDictionary>?

    private static let copyFn: CopyFn? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let sym = dlsym(handle, "CGSessionCopyCurrentDictionaryOfProperties") else {
            return nil
        }
        return unsafeBitCast(sym, to: CopyFn.self)
    }()

    static func isSharing() -> Bool {
        guard let dict = copyFn?()?.takeRetainedValue() as? [String: Any] else { return false }
        if let n = dict["CGSSessionScreenIsShared"] as? NSNumber { return n.boolValue }
        if let b = dict["CGSSessionScreenIsShared"] as? Bool { return b }
        return false
    }
}
