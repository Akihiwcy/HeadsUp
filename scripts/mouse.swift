// Posts real mouse events (test helper). Coordinates are global, top-left origin, in points.
// mouse drag x1 y1 x2 y2 | cmddrag x1 y1 x2 y2 (⌘ held) | click x y | rightclick x y | move x y
// mouse scroll x y delta [count] [--wait] | scrollpixels x y delta [count] [--wait]
// Positive delta zooms in. --wait requires a test instance and build/hctl alongside this helper.
import CoreGraphics
import Foundation
import ApplicationServices
let waitForCommit = CommandLine.arguments.contains("--wait")
let a = CommandLine.arguments.filter { $0 != "--wait" }
guard a.count > 1 else { exit(64) }
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
case "scroll", "scrollpixels":
    guard (5...6).contains(a.count), let delta = Int32(a[4]), delta != 0,
          let x = Double(a[2]), x.isFinite, let y = Double(a[3]), y.isFinite,
          let count = a.count == 6 ? Int(a[5]) : 1, count > 0 else { exit(64) }
    let hctl = URL(fileURLWithPath: a[0]).deletingLastPathComponent().appendingPathComponent("hctl")
    if waitForCommit && !FileManager.default.isExecutableFile(atPath: hctl.path) {
        fputs("Compile scripts/hctl.swift alongside mouse before using --wait.\n", stderr)
        exit(1)
    }
    let marker = Int64.random(in: 1...Int64.max)
    let point = p(2)
    post(.mouseMoved, point); usleep(150_000)
    for i in 0..<count {
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: a[1] == "scrollpixels" ? .pixel : .line,
                                  wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { exit(1) }
        event.location = point
        if i == count - 1 { event.setIntegerValueField(.eventSourceUserData, value: marker) }
        event.post(tap: .cghidEventTap)
        usleep(16_000)
    }
    if waitForCommit {
        let process = Process()
        process.executableURL = hctl
        process.arguments = ["wait-scroll", String(marker)]
        do { try process.run() }
        catch { fputs("Could not run hctl: \(error)\n", stderr); exit(1) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
        print("Last scroll event processed and viewport committed (marker \(marker)).")
    } else {
        print("Events posted; viewport commit is not confirmed. Use --wait with a test instance.")
    }
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
