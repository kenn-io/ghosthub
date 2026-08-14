import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// How many displays macOS currently reports as active.
///
/// With the lid shut and no external display attached the count is zero. Nothing
/// can render, and CoreVideo refuses to build the display link libghostty's
/// renderer needs for vsync ("invalid display count (0)"), so
/// `ghostty_surface_new` fails. Attaching in that window therefore cannot
/// succeed, and Ghosthub waits for a display instead of burning a reconnect on
/// it.
///
/// This reads the same quantity CoreVideo itself measures rather than
/// `NSScreen.screens`, so the check matches the precondition that actually
/// fails.
enum DisplayAvailability {
    static func activeCount() -> Int {
        #if canImport(CoreGraphics)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else {
            // An unreadable display list must never strand a session. Report a
            // display so the attach proceeds and reports its own real failure.
            return 1
        }
        return Int(count)
        #else
        return 1
        #endif
    }
}
