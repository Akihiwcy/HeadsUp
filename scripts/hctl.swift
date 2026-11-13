// Sends a command to a HEADSUP_TEST_CONTROL=1 instance and waits for its acknowledgement.
import Foundation
let cmd = CommandLine.arguments.dropFirst().joined(separator: " ")
guard !cmd.isEmpty else { fputs("Usage: hctl COMMAND [ARGUMENTS]\n", stderr); exit(64) }
let requestID = UUID().uuidString
let center = DistributedNotificationCenter.default()
var reply: Notification?
let observer = center.addObserver(forName: Notification.Name("app.headsup.test.reply"), object: requestID, queue: .main) {
    reply = $0
}
center.postNotificationName(Notification.Name("app.headsup.test"), object: cmd,
                            userInfo: ["requestID": requestID], deliverImmediately: true)
// Terminating the app also terminates its reply handler.
if cmd == "quit" { exit(0) }
let deadline = Date().addingTimeInterval(10)
while reply == nil && Date() < deadline {
    RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.02)))
}
center.removeObserver(observer)
guard let reply else {
    fputs("Timed out waiting for HeadsUp. Start a HEADSUP_TEST_CONTROL=1 instance; no completion was confirmed.\n", stderr)
    exit(1)
}
guard reply.userInfo?["ok"] as? Bool == true else {
    fputs("HeadsUp: \(reply.userInfo?["error"] as? String ?? "Command failed")\n", stderr)
    exit(1)
}
