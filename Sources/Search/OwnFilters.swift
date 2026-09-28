import Foundation
import WebKit

// Your own part of the blocker: filters you write, in uBlock Origin's syntax,
// and rules — uBO's dynamic filtering, "source destination type action" —
// that block or allow a site's scripts, frames or a whole third party on one
// site or everywhere. Kept as text in the profile, compiled here in a second
// into small lists of their own that load after uBO's, so a change is on the
// next page load and not after the lists' long compile.
//
// What one WebKit list can't do to another: undo its blocks. Your exceptions
// (@@…) and allow rules are handed to the lists as well (Filters.setOverrides),
// which then compile again in the background, as an update does.
//
// Neither ever acts on a sign-in, passkey, captcha or payment page, or on a
// protected host anywhere (see Protected): each list ends with the rules
// that undo it there.

@MainActor
final class OwnFilters: ObservableObject {
    static let shared = OwnFilters()

    /// Your filters, as typed.
    @Published private(set) var filters = ""
    /// Your rules, as typed.
    @Published private(set) var rules = ""
    /// How the last compile went, for Settings.
    @Published private(set) var report = Report()
    /// Up whenever new lists are in place, for open pages to be given them.
    @Published private(set) var generation = 0

    struct Report: Equatable {
        var filters = 0
        var rules = 0
        /// Lines that meant nothing to the compiler, by line number.
        var skipped: [Int] = []
        var ruleErrors: [Int] = []
        var trouble: String?
    }

    private(set) var lists: [WKContentRuleList] = []
    private(set) var table = FilterCompiler.ScriptletTable()
    private(set) var extras = FilterCompiler.Extras()
    /// Sites whose inline scripts your rules block ("site * inline-script block").
    private(set) var inlineBlocked = Set<String>()

    private var folder: URL { Store.file("filters") }
    private var filtersFile: URL { folder.appendingPathComponent("mine.txt") }
    private var rulesFile: URL { folder.appendingPathComponent("rules.txt") }
    private var store: WKContentRuleListStore? {
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("own", isDirectory: true), withIntermediateDirectories: true)
        return WKContentRuleListStore(url: folder.appendingPathComponent("own", isDirectory: true))
    }
    nonisolated static let prefix = "office-own-"

    private init() {
        filters = (try? String(contentsOf: filtersFile, encoding: .utf8)) ?? ""
        rules = (try? String(contentsOf: rulesFile, encoding: .utf8)) ?? ""
    }

    /// At launch: what you had, compiled (usually found already compiled).
    func start() { Task { await compile() } }

    func save(filters text: String) async {
        filters = text
        write(text, to: filtersFile)
        await compile()
    }

    func save(rules text: String) async {
        rules = text
        write(text, to: rulesFile)
        await compile()
    }

    /// One rule added (or its opposite replaced), from the site card or the log.
    func set(_ rule: Rule) async {
        var lines = rules.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { line in Rule(line).map { $0.source == rule.source && $0.destination == rule.destination && $0.type == rule.type } ?? false }
        if rule.action != .none { lines.append(rule.text) }
        await save(rules: lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n")
    }

    /// A filter added to yours, from the log.
    func add(filter: String) async {
        let text = filters.hasSuffix("\n") || filters.isEmpty ? filters : filters + "\n"
        await save(filters: text + filter + "\n")
    }

    /// Your rule for exactly this, if any.
    func rule(source: String, destination: String, type: String) -> Rule.Action {
        for line in rules.split(separator: "\n") {
            if let rule = Rule(String(line)), rule.source == source, rule.destination == destination, rule.type == type { return rule.action }
        }
        return .none
    }

    private func write(_ text: String, to file: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - compiling

    private func compile() async {
        let filterText = filters, ruleText = rules
        let built = await Task.detached(priority: .userInitiated) { OwnFilters.build(filters: filterText, rules: ruleText) }.value
        var report = Report(filters: built.filterCount, rules: built.ruleCount, skipped: built.skipped, ruleErrors: built.ruleErrors)
        var found: [WKContentRuleList] = []
        if let store {
            for (name, json) in built.lists {
                let identifier = OwnFilters.prefix + name + "-" + Filters.digest(json)
                if let list = try? await store.contentRuleList(forIdentifier: identifier) { found.append(list); continue }
                do {
                    if let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { found.append(list) }
                } catch {
                    // An older WebKit knows a frame as "document".
                    let older = json.replacingOccurrences(of: "\"child-document\"", with: "\"document\"")
                    if older != json, let list = try? await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: older) {
                        found.append(list)
                    } else {
                        report.trouble = "Some of your \(name == "rules" ? "rules" : "filters") couldn’t be used: \(error.localizedDescription)"
                    }
                }
            }
            let keep = Set(found.compactMap(\.identifier))
            for old in await store.availableIdentifiers() ?? [] where old.hasPrefix(OwnFilters.prefix) && !keep.contains(old) {
                try? await store.removeContentRuleList(forIdentifier: old)
            }
        }
        lists = found
        table = built.table
        extras = built.extras
        inlineBlocked = built.inlineBlocked
        self.report = report
        generation += 1
        Filters.shared.setOverrides(built.overrides)
    }

    struct Built: Sendable {
        var lists: [(String, String)] = []
        var table = FilterCompiler.ScriptletTable()
        var extras = FilterCompiler.Extras()
        var overrides: [String] = []
        var inlineBlocked = Set<String>()
        var filterCount = 0, ruleCount = 0
        var skipped: [Int] = [], ruleErrors: [Int] = []
    }

    /// Both texts into lists and tables. Pure: runs off the main thread.
    nonisolated static func build(filters: String, rules: String) -> Built {
        var built = Built()
        // Rules first: what they allow is also every list's closing.
        var parsed: [Rule] = []
        for (index, line) in rules.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#") || text.hasPrefix("!") { continue }
            guard let rule = Rule(text) else { built.ruleErrors.append(index + 1); continue }
            parsed.append(rule)
        }
        built.ruleCount = parsed.count
        let ordered = parsed.sorted { $0.specificity < $1.specificity }
        var dynamic: [String] = []
        for rule in ordered {
            if rule.type == "inline-script" {
                if rule.action == .block { built.inlineBlocked.insert(rule.source) } else { built.inlineBlocked.remove(rule.source) }
                continue
            }
            guard let json = rule.json() else { continue }
            dynamic.append(json)
            if rule.action == .allow { built.overrides.append(json) }
        }
        let protection = Protected.rules(pages: true)
        if !dynamic.isEmpty { built.lists.append(("rules", "[" + (dynamic + protection).joined(separator: ",") + "]")) }

        // Your filters, trusted as uBO trusts its own lists, ending with
        // what your rules allow and what nothing may block.
        let lines = filters.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let meaningful = lines.filter { !$0.isEmpty && !$0.hasPrefix("!") }
        built.filterCount = meaningful.count
        if !meaningful.isEmpty {
            let output = FilterCompiler.compile([(group: "mine", text: filters, trusted: true)], closing: built.overrides + protection)
            for (name, json) in output.lists { built.lists.append(("filters-" + name, json)) }
            built.table = output.scriptlets
            built.extras = output.extras
            // Your exceptions undo the lists' blocks too.
            let exceptions = FilterCompiler.compile(
                [(group: "mine", text: meaningful.filter { $0.hasPrefix("@@") && !$0.contains("#") }.joined(separator: "\n"), trusted: true)])
            for json in exceptions.lists.values {
                if let array = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] {
                    for rule in array where (rule["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules" {
                        if let data = try? JSONSerialization.data(withJSONObject: rule, options: [.sortedKeys]) {
                            built.overrides.append(String(decoding: data, as: UTF8.self))
                        }
                    }
                }
            }
            // A line that is neither a comment nor anything the compiler
            // took is worth pointing at.
            for (index, line) in lines.enumerated() where !line.isEmpty && !line.hasPrefix("!") {
                if !FilterCompiler.understands(line) { built.skipped.append(index + 1) }
            }
        }
        return built
    }

    // MARK: - a rule

    /// uBO's dynamic filtering rule: on pages of \`source\` ("*" for all),
    /// loads from \`destination\` ("*" for any) of \`type\`, blocked, allowed
    /// past every filter, or left to the filters (noop).
    struct Rule: Equatable, Sendable {
        enum Action: String, Sendable { case block, allow, noop, none }
        var source: String
        var destination: String
        var type: String
        var action: Action

        static let types: Set<String> = ["*", "3p", "3p-script", "3p-frame", "1p-script", "inline-script", "image"]

        init(source: String, destination: String, type: String, action: Action) {
            self.source = source; self.destination = destination; self.type = type; self.action = action
        }

        init?(_ line: String) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map { String($0).lowercased() }
            guard parts.count == 4, let action = Action(rawValue: parts[3]), action != .none,
                  Rule.types.contains(parts[2]), Rule.plausible(parts[0]), Rule.plausible(parts[1]),
                  parts[1] == "*" || parts[2] == "*" else { return nil }
            self.init(source: parts[0], destination: parts[1], type: parts[2], action: action)
        }

        private static func plausible(_ host: String) -> Bool {
            host == "*" || (!host.isEmpty && host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
        }

        var text: String { "\(source) \(destination) \(type) \(action.rawValue)" }

        /// Broader first: a narrower rule, later in the list, has the last word.
        var specificity: (Int, Int, Int) {
            let host = { (name: String) in name == "*" ? 0 : 1 + name.filter { $0 == "." }.count }
            let rank = type == "*" ? 0 : (type == "3p" ? 1 : 2)
            return (host(source), host(destination), rank)
        }

        func json() -> String? {
            var trigger: [String: Any] = ["url-filter": destination == "*" ? ".*"
                : #"^[a-z][a-z0-9.+-]*://([^/?#]*\.)?"# + destination.replacingOccurrences(of: ".", with: #"\."#) + "[:/?#]"]
            if source != "*" { trigger["if-domain"] = ["*" + source] }
            switch type {
            case "3p": trigger["load-type"] = ["third-party"]
            case "3p-script": trigger["load-type"] = ["third-party"]; trigger["resource-type"] = ["script"]
            case "3p-frame": trigger["load-type"] = ["third-party"]; trigger["resource-type"] = ["child-document"]
            case "1p-script": trigger["load-type"] = ["first-party"]; trigger["resource-type"] = ["script"]
            case "image": trigger["resource-type"] = ["image"]
            default: break
            }
            let rule: [String: Any] = ["trigger": trigger, "action": ["type": action == .block ? "block" : "ignore-previous-rules"]]
            return (try? JSONSerialization.data(withJSONObject: rule, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
        }
    }
}
