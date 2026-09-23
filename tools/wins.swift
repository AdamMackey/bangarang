import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w["kCGWindowLayer"] as? Int) == 0 {
    let b = w["kCGWindowBounds"] as? [String: Any] ?? [:]
    print(w["kCGWindowNumber"] ?? "", w["kCGWindowOwnerName"] ?? "", "|", (w["kCGWindowName"] as? String ?? "").prefix(60), "|", b["Width"] ?? "", "x", b["Height"] ?? "")
}
