import CoreGraphics
import Foundation
// Waits for the first ordinary window of a process on screen; prints nothing, exits 0 or 1.
let pid = Int32(CommandLine.arguments[1])!
let end = Date().addingTimeInterval(20)
while Date() < end {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    if list.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        && ((($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double) ?? 0) > 200 }) { exit(0) }
    usleep(2000)
}
exit(1)

