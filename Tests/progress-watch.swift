// Subscribes to the progress a file publishes, as the Finder does, and prints
// the fractions it sees until the file's progress is unpublished or the
// timeout passes. Used by Tests/local-resolution.py downloads:
//   swift Tests/progress-watch.swift /path/to/file.bin 20
import Foundation

let file = URL(fileURLWithPath: CommandLine.arguments[1])
let limit = Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "20") ?? 20
var seen: [Double] = []
var gone = false
var watch: NSKeyValueObservation?
let token = Progress.addSubscriber(forFileURL: file) { progress in
    seen.append(progress.fractionCompleted)
    watch = progress.observe(\.fractionCompleted) { p, _ in seen.append(p.fractionCompleted) }
    return { gone = true }
}
let end = Date().addingTimeInterval(limit)
while Date() < end && !gone { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
Progress.removeSubscriber(token)
_ = watch
let out: [String: Any] = ["seen": seen.count, "first": seen.first ?? -1, "last": seen.last ?? -1, "unpublished": gone]
print(String(data: try JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
