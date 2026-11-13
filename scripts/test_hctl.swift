// Exercises the real hctl executable against a delayed fake test-control responder.
// No HeadsUp instance, Accessibility permission or network access is required.
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Usage: swift scripts/test_hctl.swift PATH_TO_HCTL") }
let executable = URL(fileURLWithPath: CommandLine.arguments[1])
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("headsup-hctl-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let output = directory.appendingPathComponent("dump.json")
try "stale".write(to: output, atomically: true, encoding: .utf8)
let center = DistributedNotificationCenter.default()
let observer = center.addObserver(forName: Notification.Name("app.headsup.test"), object: nil, queue: .main) { note in
    guard let id = note.userInfo?["requestID"] as? String else { return }
    let command = note.object as? String ?? ""
    // A reply for an unrelated command must never unblock this caller.
    center.postNotificationName(Notification.Name("app.headsup.test.reply"), object: "unrelated-request",
                                userInfo: ["ok": true], deliverImmediately: true)
    Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
        var error = ""
        if command == "dump \(output.path)" {
            do { try "fresh".write(to: output, atomically: true, encoding: .utf8) }
            catch let failure { error = failure.localizedDescription }
        } else {
            error = "simulated dump write failure"
        }
        center.postNotificationName(Notification.Name("app.headsup.test.reply"), object: id,
                                    userInfo: ["ok": error.isEmpty, "error": error], deliverImmediately: true)
    }
}
defer { center.removeObserver(observer) }

func run(_ arguments: [String]) throws -> Int32 {
    let child = Process()
    child.executableURL = executable
    child.arguments = arguments
    try child.run()
    let deadline = Date().addingTimeInterval(5)
    while child.isRunning && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    guard !child.isRunning else { child.terminate(); fatalError("hctl did not receive the test reply") }
    return child.terminationStatus
}

let started = Date()
let success = try run(["dump", output.path])
precondition(success == 0, "Acknowledged dump failed")
let contents = try String(contentsOf: output, encoding: .utf8)
precondition(contents == "fresh", "hctl returned while the previous dump was still on disk")
precondition(Date().timeIntervalSince(started) >= 0.3, "hctl returned before the handler finished")
let failure = try run(["dump", directory.appendingPathComponent("unwritable.json").path])
precondition(failure != 0, "A dump error must not be reported as success")
print("PASS: hctl waits for its own reply, sees the new dump, and reports handler errors.")
