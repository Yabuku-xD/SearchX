import Foundation

// The filters SearchX carries out itself (FilterCompiler.Extras), matched as
// uBO matches them: $domain against the page they're on, then the pattern
// against the address. Patterns are WebKit-style regular expressions, which
// Foundation reads too; each is compiled once, and a literal piece of it is
// looked for first, so thousands of $removeparam rules cost a navigation
// almost nothing.

enum RuleMatch {
    typealias NetRule = FilterCompiler.NetRule

    private static let lock = NSLock()
    nonisolated(unsafe) private static var compiled: [String: NSRegularExpression] = [:]
    nonisolated(unsafe) private static var literals: [String: String] = [:]

    private static func regex(_ pattern: String) -> (NSRegularExpression?, String) {
        lock.lock(); defer { lock.unlock() }
        if let known = compiled[pattern] { return (known, literals[pattern] ?? "") }
        let made = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let literal = longestLiteral(pattern)
        if let made { compiled[pattern] = made }
        literals[pattern] = literal
        return (made, literal)
    }

    /// The longest run of plain characters in a pattern, "\." read as "."
    /// — every address it matches contains it.
    private static func longestLiteral(_ pattern: String) -> String {
        func longer(_ a: String, _ b: String) -> String { b.count > a.count ? b : a }
        var best = "", current = ""
        var escaped = false
        var inClass = 0
        for character in pattern {
            if escaped {
                if character == "." || character == "/" || character == "-" { current.append(character) } else { best = longer(best, current); current = "" }
                escaped = false
                continue
            }
            if character == "\\" { escaped = true; continue }
            if character == "[" { inClass += 1 }
            if character == "]" { inClass -= 1; best = longer(best, current); current = ""; continue }
            if inClass == 0, character.isLetter || character.isNumber || character == "_" || character == "=" || character == "/" || character == "-" {
                current.append(character)
            } else {
                // A quantifier makes the character before it optional.
                if "?*".contains(character), !current.isEmpty { current.removeLast() }
                best = longer(best, current); current = ""
            }
        }
        return longer(best, current).lowercased()
    }

    private static func within(_ host: String, _ domains: [String]) -> Bool {
        domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Whether a rule is for this address, on a page at \`context\`.
    static func applies(_ rule: NetRule, to url: URL, context: String?) -> Bool {
        let host = (context ?? url.host() ?? "").lowercased()
        if !rule.ifDomain.isEmpty && !within(host, rule.ifDomain) { return false }
        if !rule.unlessDomain.isEmpty && within(host, rule.unlessDomain) { return false }
        guard let pattern = rule.pattern else { return true }
        let address = url.absoluteString
        let (regex, literal) = regex(pattern)
        if !literal.isEmpty, !address.lowercased().contains(literal) { return false }
        guard let regex else { return false }
        return regex.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) != nil
    }

    // MARK: - $removeparam

    struct Removal {
        let value: String
        /// A name, or /regex/ tested against "name=value".
        func removes(_ item: URLQueryItem) -> Bool {
            if value.count > 2, value.hasPrefix("/"), let end = value.lastIndex(of: "/"), end > value.startIndex {
                let body = String(value[value.index(after: value.startIndex)..<end])
                let flags = value[value.index(after: end)...]
                guard let regex = try? NSRegularExpression(pattern: body, options: flags.contains("i") ? [.caseInsensitive] : []) else { return false }
                let pair = item.name + "=" + (item.value ?? "")
                return regex.firstMatch(in: pair, range: NSRange(pair.startIndex..., in: pair)) != nil
            }
            return item.name == value
        }
    }

    enum Removals { case none, all, some([Removal]) }

    static func removals(for url: URL, in rules: [NetRule]) -> Removals {
        let here = rules.filter { applies($0, to: url, context: nil) }
        guard !here.isEmpty else { return .none }
        let cancelled = Set(here.filter(\.exception).map(\.value))
        if cancelled.contains("") { return .none }
        let wanted = here.filter { !$0.exception && !cancelled.contains($0.value) }
        if wanted.contains(where: { $0.value.isEmpty }) { return .all }
        return wanted.isEmpty ? .none : .some(wanted.map { Removal(value: $0.value) })
    }

    // MARK: - $csp

    /// The policies a document at this address is given.
    static func policies(for url: URL, in rules: [NetRule]) -> [String] {
        let here = rules.filter { applies($0, to: url, context: nil) }
        let cancelled = Set(here.filter(\.exception).map(\.value))
        if cancelled.contains("") { return [] }
        return Array(Set(here.filter { !$0.exception && !$0.value.isEmpty && !cancelled.contains($0.value) }.map(\.value))).sorted()
    }

    // MARK: - $header

    /// Whether a document's response is refused for a header it carries:
    /// "name", "name:value" or "name:/regex/", "~" before the value for
    /// "any value but".
    static func refuses(_ response: HTTPURLResponse, url: URL, context: String?, in rules: [NetRule]) -> Bool {
        let here = rules.filter { applies($0, to: url, context: context) }
        guard !here.isEmpty else { return false }
        let cancelled = Set(here.filter(\.exception).map(\.value))
        if cancelled.contains("") { return false }
        for rule in here where !rule.exception && !cancelled.contains(rule.value) {
            let parts = rule.value.split(separator: ":", maxSplits: 1).map(String.init)
            guard let name = parts.first, !name.isEmpty, let present = response.value(forHTTPHeaderField: name) else { continue }
            guard parts.count == 2 else { return true }
            var wanted = parts[1]
            let negated = wanted.hasPrefix("~")
            if negated { wanted.removeFirst() }
            var hit: Bool
            if wanted.count > 2, wanted.hasPrefix("/"), wanted.hasSuffix("/"),
               let regex = try? NSRegularExpression(pattern: String(wanted.dropFirst().dropLast()), options: [.caseInsensitive]) {
                hit = regex.firstMatch(in: present, range: NSRange(present.startIndex..., in: present)) != nil
            } else {
                hit = present.caseInsensitiveCompare(wanted) == .orderedSame
            }
            if negated { hit.toggle() }
            if hit { return true }
        }
        return false
    }

    // MARK: - for a page's own script

    /// The rules a page's script needs, as JSON: those that could apply to
    /// documents on this site, patterns and values only. \`ownSite\`: a rule
    /// naming no site but anchored to a host ("||youtube.com/…") is only for
    /// pages on that host's site — a page's own requests, as $replace's are.
    static func forPage(_ rules: [NetRule], host: String, ownSite: Bool = false,
                        keep: (NetRule) -> Bool = { _ in true }) -> [[String: String]] {
        rules.filter { rule in
            guard keep(rule), rule.ifDomain.isEmpty || within(host, rule.ifDomain), !within(host, rule.unlessDomain) else { return false }
            if ownSite, rule.ifDomain.isEmpty, let anchored = anchoredHost(rule.pattern) {
                return host == anchored || host.hasSuffix("." + anchored) || Intent.sameSite(host, anchored)
            }
            return true
        }.map { ["pattern": $0.pattern ?? "", "value": $0.value, "exception": $0.exception ? "1" : ""] }
    }

    /// The host a "||host…" pattern (FilterCompiler.Pattern.urlFilter) is
    /// anchored to, if it is.
    static func anchoredHost(_ pattern: String?) -> String? {
        let prefix = FilterCompiler.Pattern.scheme
        guard let pattern, pattern.hasPrefix(prefix) else { return nil }
        var host = ""
        var rest = pattern.dropFirst(prefix.count)
        while let character = rest.first {
            if character == "\\", rest.dropFirst().first == "." { host.append("."); rest = rest.dropFirst(2); continue }
            guard character.isLetter || character.isNumber || character == "-" else { break }
            host.append(character)
            rest = rest.dropFirst()
        }
        return host.contains(".") ? host.lowercased() : nil
    }
}
