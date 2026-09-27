import Foundation
import WebKit

// Compiling uBO's lists is the heaviest thing Search ever does: reading
// seven megabytes of filters and WebKit turning them into its matching
// machines peaks near a gigabyte. Done inside the browser, most of that
// stayed on its books long after (446 MB ten seconds after a compile, 22 MB
// of it live). So Search runs a second copy of itself to do it, which
// writes the compiled lists into the rule store and quits; macOS takes every
// byte back, and the browser only ever opens the finished lists, which
// WebKit maps from disk and shares between every page.
//
//   Search --compile-filters <lists folder> <rule store folder> <result file>

enum FilterWorker {
    static let flag = "--compile-filters"

    struct Result: Codable {
        var identifiers: [String]
        var table: FilterCompiler.ScriptletTable
        var popupHosts: [String]
        var counts: [String: Int]
    }

    /// When this process was started to compile, compiles and exits;
    /// otherwise returns at once. Called before anything else at launch.
    static func runIfAsked() {
        let arguments = CommandLine.arguments
        guard arguments.count == 5, arguments[1] == flag else { return }
        let lists = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let storeFolder = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let resultFile = URL(fileURLWithPath: arguments[4])
        try? FileManager.default.createDirectory(at: storeFolder, withIntermediateDirectories: true)
        guard let store = WKContentRuleListStore(url: storeFolder) else { exit(2) }
        let sources = Filters.sources.compactMap { source -> (group: String, text: String)? in
            let file = lists.appendingPathComponent(source.id + ".txt")
            return (try? String(contentsOf: file, encoding: .utf8)).map { (group: source.group, text: $0) }
        }
        guard !sources.isEmpty else { exit(3) }
        attempt(sources, modern: true, store: store, resultFile: resultFile)
        RunLoop.main.run()
    }

    /// Modern resource type names first; an older WebKit that refuses them
    /// gets the older names. One list at a time, each list's text let go
    /// once it is compiled: the peak is the largest list's, not all three's.
    private static func attempt(_ sources: [(group: String, text: String)], modern: Bool,
                                store: WKContentRuleListStore, resultFile: URL) {
        let output = FilterCompiler.compile(sources, modernTypes: modern)
        var pending = output.lists.sorted { $0.key < $1.key }.map { (group: $0.key, json: $0.value) }
        var result = Result(identifiers: [], table: output.scriptlets, popupHosts: output.popupHosts, counts: output.counts)
        guard !pending.isEmpty else { exit(3) }
        func next() {
            guard !pending.isEmpty else {
                guard let data = try? JSONEncoder().encode(result),
                      (try? data.write(to: resultFile, options: .atomic)) != nil else { exit(4) }
                exit(0)
            }
            let (group, json) = pending.removeFirst()
            let identifier = Filters.prefix + group + "-" + Filters.digest(json)
            let finish: (Bool) -> Void = { ok in
                guard ok else {
                    if modern { attempt(sources, modern: false, store: store, resultFile: resultFile) } else { exit(5) }
                    return
                }
                result.identifiers.append(identifier)
                next()
            }
            store.lookUpContentRuleList(forIdentifier: identifier) { known, _ in
                if known != nil { finish(true); return }
                store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, _ in
                    finish(list != nil)
                }
            }
        }
        next()
    }
}
