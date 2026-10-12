// Sends a test command to a running HeadsUp started with HEADSUP_TEST_CONTROL=1.
import Foundation
let cmd = CommandLine.arguments.dropFirst().joined(separator: " ")
DistributedNotificationCenter.default().postNotificationName(Notification.Name("app.headsup.test"), object: cmd, userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
