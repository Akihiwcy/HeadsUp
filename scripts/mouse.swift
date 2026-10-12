// Posts real mouse events (test helper). Coordinates are global, top-left origin, in points.
// mouse drag x1 y1 x2 y2 | cmddrag x1 y1 x2 y2 (⌘ held) | click x y | rightclick x y | move x y
import CoreGraphics
import Foundation
import ApplicationServices
let a = CommandLine.arguments
func p(_ i: Int) -> CGPoint { CGPoint(x: Double(a[i])!, y: Double(a[i + 1])!) }
var flags: CGEventFlags = []
func post(_ t: CGEventType, _ at: CGPoint, _ b: CGMouseButton = .left) {
    guard let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: at, mouseButton: b) else { return }
    if !flags.isEmpty { e.flags = flags }
    e.post(tap: .cghidEventTap)
    usleep(16_000)
}
let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
print("trusted:", trusted)
if !trusted { exit(2) }
switch a[1] {
case "move": post(.mouseMoved, p(2))
case "click":
    post(.mouseMoved, p(2)); usleep(150_000); post(.leftMouseDown, p(2)); usleep(60_000); post(.leftMouseUp, p(2))
case "rightclick":
    post(.mouseMoved, p(2)); usleep(150_000); post(.rightMouseDown, p(2), .right); usleep(60_000); post(.rightMouseUp, p(2), .right)
case "cmddrag", "drag":
    if a[1] == "cmddrag" { flags = .maskCommand }
    let s = p(2), e = p(4)
    post(.mouseMoved, s); usleep(300_000); post(.leftMouseDown, s)
    for i in 1...30 {
        let t = Double(i) / 30
        post(.leftMouseDragged, CGPoint(x: s.x + (e.x - s.x) * t, y: s.y + (e.y - s.y) * t))
    }
    post(.leftMouseUp, e)
default: break
}
