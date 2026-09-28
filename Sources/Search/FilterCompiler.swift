import Foundation

// uBlock Origin's filter syntax, turned into what WebKit's own content blocker
// runs, plus what it cannot run: the scriptlets a site gets (see Scriptlets)
// and the hosts a pop-up may not open onto (see Shield). Pure and off the main
// thread: it reads the lists as text and hands back JSON and tables.
//
// What maps, and how (uBO's syntax: github.com/gorhill/uBlock/wiki/Static-filter-syntax;
// WebKit's: developer.apple.com, "Creating a content blocker"):
//
//   ||host^, |start, end|, *, ^            url-filter regular expressions
//   $third-party, $1p/$3p                  load-type
//   $script, $image, $xhr, $frame, …, ~type  resource-type
//   $popup, $popunder, $all                pop-ups blocked by WebKit, and by host
//   $domain=a|~b, $from=                   if-domain / unless-domain
//   @@…                                    ignore-previous-rules, after every block
//   $important                             after the exceptions, so none undoes it
//   $badfilter                             the filter it names is dropped
//   host##selector, ##selector             css-display-none, grouped by site
//   host#@#selector                        the generic selector, unless on that site
//   @@||host^$generichide / $elemhide      generic hiding off on that site
//   host##+js(name, args)                  a scriptlet, run by Scriptlets
//   !#if … / !#else / !#endif              uBO's preprocessor, as a WebKit browser
//
// What does not: $redirect is a block (uBO would substitute a neutered
// script; WebKit cannot); $removeparam, $csp, $header, $replace, $permissions
// and procedural cosmetic filters (:has-text, :upward, …) are left out;
// regular expressions WebKit's engine rejects (alternation, \d, {n}) too.

enum FilterCompiler {
    /// Rules per compiled list; see `emit`.
    static let partSize = 25_000

    struct Output: Codable {
        /// Content-blocker JSON, one list per group.
        var lists: [String: String]
        var scriptlets: ScriptletTable
        /// Hosts whose pop-ups never open, from $popup/$popunder/$all filters.
        var popupHosts: [String]
        var counts: [String: Int]
        /// What WebKit's blocker can't do, done by SearchX (see Extras).
        var extras = Extras()
    }

    /// A network filter whose work is not WebKit's blocker's: where it
    /// applies (a pattern over the address, nil for any; the sites it is on
    /// or off), and what it says.
    struct NetRule: Codable, Hashable {
        var pattern: String?
        var ifDomain: [String] = []
        var unlessDomain: [String] = []
        var value = ""
        var exception = false
    }

    /// The parts of uBO's syntax SearchX carries out itself: procedural
    /// cosmetic filters (by site), and $removeparam, $csp, $header,
    /// $replace and $redirect.
    struct Extras: Codable {
        var procedural: [String: [String]] = [:]
        var proceduralOff: [String: [String]] = [:]
        var removeparam: [NetRule] = []
        var csp: [NetRule] = []
        var header: [NetRule] = []
        var replace: [NetRule] = []
        var redirect: [NetRule] = []

        /// Two tables as one: lists' and yours.
        func merged(with other: Extras) -> Extras {
            var out = self
            out.procedural.merge(other.procedural) { $0 + $1 }
            out.proceduralOff.merge(other.proceduralOff) { $0 + $1 }
            out.removeparam += other.removeparam
            out.csp += other.csp
            out.header += other.header
            out.replace += other.replace
            out.redirect += other.redirect
            return out
        }
    }

    struct ScriptletTable: Codable {
        /// Each scriptlet as uBO writes it: its name, then its arguments.
        var calls: [[String]] = []
        /// Host, or entity ("site.*"), to the calls that run there.
        var byHost: [String: [Int]] = [:]
        /// Calls that run everywhere but these hosts.
        var except: [Int: [String]] = [:]
        /// Host to the calls turned off there ("" is all of them).
        var off: [String: [String]] = [:]
        var generic: [Int] = []
    }

    /// Where each list goes. Exceptions go into every list: one list's
    /// exception cannot reach another list's rule.
    /// A source is \`trusted\` when its filters may do what uBO lets only its
    /// own lists and yours do ($replace). \`closing\`: rules put last in every
    /// list, after its exceptions and what no exception undoes — your
    /// exceptions and allow rules, then the protected hosts (see Protected).
    static func compile(_ sources: [(group: String, text: String, trusted: Bool)], modernTypes: Bool = true,
                        closing: [String] = []) -> Output {
        var parser = Parser(modernTypes: modernTypes)
        parser.closing = closing
        for source in sources { parser.read(source.text, group: source.group, trusted: source.trusted) }
        return parser.finish()
    }

    /// Whether one line is a filter this compiler uses — for pointing at the
    /// ones in your filters it doesn't.
    static func understands(_ line: String) -> Bool {
        let output = compile([(group: "check", text: line, trusted: true)])
        let extras = output.extras
        return !output.lists.isEmpty || !output.scriptlets.calls.isEmpty || !output.scriptlets.off.isEmpty
            || !extras.procedural.isEmpty || !extras.proceduralOff.isEmpty || !extras.removeparam.isEmpty
            || !extras.csp.isEmpty || !extras.header.isEmpty || !extras.replace.isEmpty || !extras.redirect.isEmpty
            || !output.popupHosts.isEmpty
    }

    // MARK: - parsing

    private struct Parser {
        let modernTypes: Bool
        // Each rule as its JSON text, made once: kept as dictionaries of Any
        // and bridged for one final encoding, the lists took 850 MB to
        // convert; as text, the list is those texts joined.
        var blocks: [String: [String]] = [:]
        var importants: [String: [String]] = [:]
        var exceptions: [String] = []
        var seen = Set<String>()
        var badfilters = Set<String>()
        var pending: [(line: String, group: String, trusted: Bool)] = []
        var closing: [String] = []
        var extras = Extras()

        // Cosmetics: selectors by the sites they apply to.
        var generic: [String: String] = [:]            // selector -> group
        var genericExcept: [String: Set<String>] = [:] // selector -> sites it is off on
        var genericKilled = Set<String>()
        var specific: [String: [String: [String]]] = [:] // group -> site key -> selectors
        var noGeneric = Set<String>()                  // sites with $generichide/$elemhide
        var popupHosts = Set<String>()
        var table = ScriptletTable()
        var callIndex: [String: Int] = [:]
        var counts: [String: Int] = [:]

        init(modernTypes: Bool) { self.modernTypes = modernTypes }

        mutating func read(_ text: String, group: String, trusted: Bool = false) {
            var skipping: [Bool] = []
            for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("!#if ") {
                    skipping.append(!Preprocessor.holds(String(line.dropFirst(5))))
                    continue
                }
                if line.hasPrefix("!#else") { if let last = skipping.popLast() { skipping.append(!last) }; continue }
                if line.hasPrefix("!#endif") { _ = skipping.popLast(); continue }
                if skipping.contains(true) { continue }
                if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
                // Hosts files: "0.0.0.0 host".
                if line.hasPrefix("0.0.0.0 ") || line.hasPrefix("127.0.0.1 ") {
                    let host = line.split(separator: " ", omittingEmptySubsequences: true).dropFirst().first.map(String.init) ?? ""
                    if !host.isEmpty, host != "localhost", host != "0.0.0.0" { pending.append(("||\(host)^", group, trusted)) }
                    continue
                }
                if line.hasPrefix("#") && !line.hasPrefix("##") && !line.hasPrefix("#@#") && !line.hasPrefix("#?#") { continue }
                if line.contains("$badfilter") || line.contains(",badfilter") {
                    badfilters.insert(line.replacingOccurrences(of: ",badfilter", with: "").replacingOccurrences(of: "$badfilter", with: ""))
                    continue
                }
                pending.append((line, group, trusted))
            }
        }

        mutating func finish() -> Output {
            for (line, group, trusted) in pending where !badfilters.contains(line) {
                // Foundation's string calls leave bridged temporaries to the
                // autorelease pool; drained only at the end, 170,000 lines of
                // them took this from 38 MB to 729 MB.
                autoreleasepool {
                    if !cosmetic(line, group: group) { network(line, group: group, trusted: trusted) }
                }
            }
            return emit()
        }

        // MARK: cosmetic

        /// True when the line was a cosmetic filter (used or not).
        mutating func cosmetic(_ line: String, group: String) -> Bool {
            for marker in ["#@#", "##", "#?#", "#@?#", "#$#", "#@$#", "#%#", "#@%#"] {
                guard let range = line.range(of: marker) else { continue }
                // A network filter's option can carry a "#" too; cosmetic
                // markers come before any "$" of a network filter's options.
                let sites = String(line[..<range.lowerBound])
                let body = String(line[range.upperBound...])
                let exception = marker.contains("@")
                if marker.contains("$") || marker.contains("%") { return true }
                if body.hasPrefix("+js(") {
                    scriptlet(sites: sites, body: body, exception: exception)
                    return true
                }
                // Procedural (:has-text, :upward, :remove…), for SearchX's own
                // script to carry out on the sites named.
                if Selector.procedural(body) {
                    procedural(sites: sites, body: body, exception: exception)
                    return true
                }
                guard Selector.plausible(body) else { return true }
                let parsed = Sites.split(sites)
                // "site>>" is the site and the frames inside it; for hiding,
                // the site is as close as a stylesheet gets. A list of sites
                // none of which could be read is not "every site".
                let positive = parsed.positive.union(parsed.ancestors), negative = parsed.negative
                if positive.isEmpty && parsed.unread { return true }
                if exception {
                    if positive.isEmpty { genericKilled.insert(body) } else { genericExcept[body, default: []].formUnion(positive) }
                    return true
                }
                if positive.isEmpty {
                    if generic[body] == nil { generic[body] = group }
                    if !negative.isEmpty { genericExcept[body, default: []].formUnion(negative) }
                } else {
                    specific[group, default: [:]][positive.sorted().joined(separator: ","), default: []].append(body)
                }
                counts["cosmetic", default: 0] += 1
                return true
            }
            return false
        }

        mutating func procedural(sites: String, body: String, exception: Bool) {
            guard !body.hasPrefix("^"), body.count < 2000 else { return }
            let parsed = Sites.split(sites)
            let positive = parsed.positive.union(parsed.ancestors)
            // uBO runs none of these everywhere: each is for the sites it names.
            guard !positive.isEmpty else { return }
            for site in positive {
                if exception { extras.proceduralOff[site, default: []].append(body) }
                else { extras.procedural[site, default: []].append(body) }
            }
            if !exception { counts["procedural", default: 0] += 1 }
        }

        mutating func scriptlet(sites: String, body: String, exception: Bool) {
            guard let close = body.lastIndex(of: ")") else { return }
            let inside = String(body[body.index(body.startIndex, offsetBy: 4)..<close])
            let call = Scriptlet.arguments(inside)
            let parsed = Sites.split(sites)
            let (positive, negative) = (parsed.positive, parsed.negative)
            // Sites that could not be read (a /regex/) leave nothing to go by:
            // skipped, rather than run on every site.
            if positive.isEmpty && parsed.ancestors.isEmpty && parsed.unread { return }
            if exception {
                let key = call.first.map { _ in call.joined(separator: ",") } ?? ""
                for host in positive.union(parsed.ancestors) { table.off[host, default: []].append(key) }
                return
            }
            guard let name = call.first, !name.isEmpty, !name.hasPrefix("trusted-") || Scriptlet.trustedAllowed.contains(name) else { return }
            let key = call.joined(separator: "\u{1}")
            let index: Int
            if let known = callIndex[key] {
                index = known
            } else {
                index = table.calls.count
                table.calls.append(call)
                callIndex[key] = index
            }
            if positive.isEmpty && parsed.ancestors.isEmpty {
                table.generic.append(index)
                if !negative.isEmpty { table.except[index, default: []].append(contentsOf: negative) }
            } else {
                for host in positive { table.byHost[host, default: []].append(index) }
                // "site>>": the site itself and every frame on its pages,
                // where its video player and its pop-ups usually live.
                for host in parsed.ancestors {
                    table.byHost[host, default: []].append(index)
                    table.byHost[host + ">>", default: []].append(index)
                }
            }
            counts["scriptlet", default: 0] += 1
        }

        // MARK: network

        /// Where a filter's options start: the last "$" that begins one —
        /// a value can carry a "$" of its own (removeparam=/^x$/).
        static func optionStart(_ line: String) -> String.Index? {
            var index = line.endIndex
            while let dollar = line[..<index].lastIndex(of: "$") {
                let rest = line[line.index(after: dollar)...]
                let first = rest.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
                let key = (first.hasPrefix("~") ? String(first.dropFirst()) : first)
                    .split(separator: "=", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
                if Parser.known.contains(key) || Types.map[key] != nil { return dollar }
                index = dollar
            }
            return nil
        }

        static let known: Set<String> = [
            "third-party", "3p", "first-party", "1p", "important", "match-case", "domain", "from", "popup", "popunder",
            "all", "generichide", "ghide", "elemhide", "ehide", "specifichide", "shide", "redirect", "redirect-rule",
            "document", "doc", "removeparam", "csp", "header", "replace", "badfilter", "to", "denyallow", "method",
            "permissions", "empty", "mp4", "strict1p", "strict3p", "cname", "ipaddress", "urlskip", "uritransform",
        ]

        /// Options split on their commas, not on a comma escaped in a value.
        static func options(_ text: Substring) -> [String] {
            var out: [String] = [], current = "", escaped = false
            for character in text {
                if escaped { current.append(character); escaped = false; continue }
                if character == "\\" { escaped = true; current.append(character); continue }
                if character == "," { out.append(current); current = ""; continue }
                current.append(character)
            }
            out.append(current)
            return out.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\,", with: ",") }.filter { !$0.isEmpty }
        }

        mutating func network(_ raw: String, group: String, trusted: Bool = false) {
            var line = raw
            let exception = line.hasPrefix("@@")
            if exception { line.removeFirst(2) }
            var pattern = line
            var optionText: Substring?
            // Options follow the last "$" that starts one. A regular
            // expression, /…/, is followed by them directly ("/…/$script").
            if let dollar = Parser.optionStart(line), !(line.hasPrefix("/") && line[..<dollar].count < 2) {
                pattern = String(line[..<dollar])
                optionText = line[line.index(after: dollar)...]
            }
            let options = Parser.options(optionText ?? "")
            var trigger: [String: Any] = [:]
            var types = Set<String>()
            var negatedTypes = Set<String>()
            var important = false
            var ifDomain: [String] = []
            var unlessDomain: [String] = []
            var popup = false
            var cosmeticOff = false
            // One of the options SearchX carries out itself, and its value.
            var special: (kind: String, value: String)?
            for option in options {
                let (negated, name) = option.hasPrefix("~") ? (true, String(option.dropFirst())) : (false, option)
                let key = name.split(separator: "=", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
                let value = name.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                switch key {
                case "third-party", "3p": trigger["load-type"] = [negated ? "first-party" : "third-party"]
                case "first-party", "1p": trigger["load-type"] = [negated ? "third-party" : "first-party"]
                case "important": important = true
                case "match-case": trigger["url-filter-is-case-sensitive"] = true
                case "domain", "from":
                    let value = name.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                    let parsed = Sites.split(value.replacingOccurrences(of: "|", with: ","))
                    let positive = parsed.positive.union(parsed.ancestors), negative = parsed.negative
                    if positive.isEmpty && parsed.unread { return }
                    ifDomain += positive.filter { !$0.hasSuffix(".*") }.sorted()
                    unlessDomain += negative.filter { !$0.hasSuffix(".*") }.sorted()
                    if !positive.isEmpty && ifDomain.isEmpty { return } // only entities: cannot say
                case "popup", "popunder":
                    popup = true
                    types.insert("popup")
                case "all":
                    popup = true
                case "generichide", "ghide", "elemhide", "ehide", "specifichide", "shide":
                    cosmeticOff = true
                case "redirect", "redirect-rule":
                    special = (key, value)
                case "removeparam", "csp", "header":
                    special = (key, value)
                case "replace":
                    // uBO takes these only from its own lists and yours.
                    guard trusted else { return }
                    special = (key, value)
                case "document", "doc":
                    if negated { continue }
                    types.insert(modernTypes ? "top-document" : "document")
                default:
                    if let mapped = Types.map[key] {
                        if negated { negatedTypes.formUnion(mapped(modernTypes)) } else { types.formUnion(mapped(modernTypes)) }
                    } else {
                        // An option this cannot honour changes what the
                        // filter means: better no filter than a wrong one.
                        return
                    }
                }
            }
            // A generichide exception: generic hiding off on these sites.
            if cosmeticOff {
                if exception, let host = Pattern.host(of: pattern) { noGeneric.insert(host) }
                return
            }
            if let special {
                let body = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                let rule = NetRule(pattern: body.isEmpty ? nil : Pattern.urlFilter(pattern),
                                   ifDomain: ifDomain, unlessDomain: unlessDomain,
                                   value: special.value, exception: exception)
                // A pattern this couldn't read is no filter at all.
                if !body.isEmpty && rule.pattern == nil { return }
                switch special.kind {
                case "removeparam": extras.removeparam.append(rule)
                case "csp": extras.csp.append(rule)
                case "header": extras.header.append(rule)
                case "replace": extras.replace.append(rule)
                default:
                    // A script's stand-in; images and the rest are blocked plainly.
                    let name = special.value.split(separator: ":").first.map(String.init) ?? ""
                    if !name.isEmpty || exception {
                        extras.redirect.append(NetRule(pattern: rule.pattern, ifDomain: ifDomain, unlessDomain: unlessDomain,
                                                       value: name, exception: exception))
                    }
                }
                counts[special.kind, default: 0] += 1
                // $redirect blocks, and its stand-in answers for what was
                // blocked; everything else here is SearchX's work alone.
                guard special.kind == "redirect", !exception else { return }
            }
            // An option with a "$" or "/" of its own (removeparam=/…/) leaves
            // part of itself behind in the pattern: not a filter to guess at.
            if !pattern.hasPrefix("/"), pattern.contains("$") { return }
            guard let filter = Pattern.urlFilter(pattern) else { return }
            trigger["url-filter"] = filter
            if !negatedTypes.isEmpty {
                types = Types.everything(modernTypes).subtracting(negatedTypes)
            }
            if types.isEmpty && !popup {
                // uBO's default: every kind of load, but a page itself only
                // when the filter names nothing but a host (strict blocking).
                if !Pattern.isHostOnly(pattern) { types = Types.everything(modernTypes) }
            }
            if !types.isEmpty { trigger["resource-type"] = Array(types).sorted() }
            if !ifDomain.isEmpty { trigger["if-domain"] = ifDomain.map { "*" + $0 } }
            else if !unlessDomain.isEmpty { trigger["unless-domain"] = unlessDomain.map { "*" + $0 } }
            if popup, !exception, ifDomain.isEmpty, let host = Pattern.host(of: pattern) { popupHosts.insert(host) }

            let rule: [String: Any] = ["trigger": trigger, "action": ["type": exception ? "ignore-previous-rules" : "block"]]
            guard let text = Parser.encode(rule), seen.insert(text).inserted else { return }
            if exception { exceptions.append(text); counts["exception", default: 0] += 1 }
            else if important { importants[group, default: []].append(text); counts["network", default: 0] += 1 }
            else { blocks[group, default: []].append(text); counts["network", default: 0] += 1 }
        }

        /// One rule as JSON, keys sorted: the same filters make the same
        /// text, so the same compiled list is found again rather than rebuilt.
        static func encode(_ rule: [String: Any]) -> String? {
            (try? JSONSerialization.data(withJSONObject: rule, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
        }

        // MARK: output

        mutating func emit() -> Output {
            var lists: [String: String] = [:]
            let groups = Set(blocks.keys).union(specific.keys).union(generic.values).union(importants.keys)
            for group in groups.sorted() {
                var rules = blocks[group] ?? []
                func add(_ rule: [String: Any]) { if let text = Parser.encode(rule) { rules.append(text) } }
                // Generic hiding, in chunks, off where a site turned it off.
                let selectors = generic.filter { $0.value == group && !genericKilled.contains($0.key) }.map(\.key).sorted()
                let plain = selectors.filter { genericExcept[$0] == nil }
                let off = noGeneric.sorted().map { "*" + $0 }
                for chunk in stride(from: 0, to: plain.count, by: 400).map({ Array(plain[$0..<min($0 + 400, plain.count)]) }) {
                    var trigger: [String: Any] = ["url-filter": ".*"]
                    if !off.isEmpty { trigger["unless-domain"] = off }
                    add(["trigger": trigger, "action": ["type": "css-display-none", "selector": Selector.list(chunk)]])
                }
                for selector in selectors where genericExcept[selector] != nil {
                    let sites = Set(genericExcept[selector] ?? []).union(noGeneric).sorted().map { "*" + $0 }
                    add(["trigger": ["url-filter": ".*", "unless-domain": sites],
                                  "action": ["type": "css-display-none", "selector": Selector.list([selector])]])
                }
                for (key, list) in (specific[group] ?? [:]).sorted(by: { $0.key < $1.key }) {
                    let sites = key.split(separator: ",").map(String.init)
                    let hosts = sites.filter { !$0.hasSuffix(".*") }
                    let entities = sites.filter { $0.hasSuffix(".*") }
                    for chunk in stride(from: 0, to: list.count, by: 400).map({ Array(list[$0..<min($0 + 400, list.count)]) }) {
                        let selector = Selector.list(chunk)
                        if !hosts.isEmpty {
                            add(["trigger": ["url-filter": ".*", "if-domain": hosts.map { "*" + $0 }],
                                          "action": ["type": "css-display-none", "selector": selector]])
                        }
                        if !entities.isEmpty {
                            add(["trigger": ["url-filter": ".*", "if-top-url": entities.map(Sites.entityFilter)],
                                          "action": ["type": "css-display-none", "selector": selector]])
                        }
                    }
                }
                // Blocks, then every exception, then what no exception undoes.
                let limit = 149_000 - exceptions.count - (importants[group]?.count ?? 0) - closing.count
                if rules.count > limit { rules = Array(rules.prefix(max(0, limit))) }
                // In parts: WebKit's compiler needs memory in proportion to
                // the largest list it is given (82,000 rules peaked at about a
                // gigabyte), and a page checks several lists as fast as one.
                // Each part carries every exception, since one list's
                // exception cannot reach another's rule; what no exception
                // undoes comes last in the last part.
                let parts = stride(from: 0, to: max(rules.count, 1), by: FilterCompiler.partSize).map {
                    Array(rules[$0..<min($0 + FilterCompiler.partSize, rules.count)])
                }
                for (index, part) in parts.enumerated() {
                    var list = part + exceptions
                    if index == parts.count - 1 { list += importants[group] ?? [] }
                    // Last of all, in every part: your exceptions and allow
                    // rules, then the hosts nothing may block (Protected).
                    list += closing
                    let name = parts.count == 1 ? group : group + "-" + String(index + 1)
                    lists[name] = "[" + list.joined(separator: ",") + "]"
                    counts["rules-" + name] = list.count
                }
            }
            return Output(lists: lists, scriptlets: table, popupHosts: popupHosts.sorted(), counts: counts, extras: extras)
        }
    }

    // MARK: - pieces

    enum Pattern {
        static let separator = "[^a-zA-Z0-9_.%-]"
        static let scheme = "^[a-z][a-z0-9.+-]*:(//)?([^/?#]*\\.)?"

        /// "||host^" or "||host" and nothing else: the host.
        static func host(of pattern: String) -> String? {
            guard pattern.hasPrefix("||") else { return nil }
            var host = pattern.dropFirst(2)
            if host.hasSuffix("^") { host = host.dropLast() }
            guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }), host.contains(".") else { return nil }
            return host.lowercased()
        }

        static func isHostOnly(_ pattern: String) -> Bool { host(of: pattern) != nil }

        static func urlFilter(_ raw: String) -> String? {
            if raw.count > 2, raw.hasPrefix("/"), raw.hasSuffix("/") {
                let body = String(raw.dropFirst().dropLast())
                return Regex.supported(body) ? body : nil
            }
            var pattern = Substring(raw)
            var out = ""
            if pattern.hasPrefix("||") { out = scheme; pattern = pattern.dropFirst(2) }
            else if pattern.hasPrefix("|") { out = "^"; pattern = pattern.dropFirst() }
            var anchored = false
            if pattern.hasSuffix("|") { anchored = true; pattern = pattern.dropLast() }
            while pattern.hasPrefix("*") { pattern = pattern.dropFirst() }
            while pattern.hasSuffix("*") && !pattern.hasSuffix("\\*") { pattern = pattern.dropLast() }
            if pattern.isEmpty { return out.isEmpty ? nil : out }
            let characters = Array(pattern)
            for (index, character) in characters.enumerated() {
                switch character {
                case "*": if !out.hasSuffix(".*") { out += ".*" }
                case "^":
                    out += index == characters.count - 1 && !anchored ? "(" + separator + ".*)?$" : separator
                case ".", "+", "?", "(", ")", "[", "]", "{", "}", "\\", "|", "$": out += "\\" + String(character)
                default:
                    guard character.isASCII, !character.isWhitespace else { return nil }
                    out.append(character)
                }
            }
            if anchored { out += "$" }
            return out
        }
    }

    enum Regex {
        /// What WebKit's content-blocker engine takes: no alternation, no
        /// counted repeats, no shorthand classes, no look-around.
        static func supported(_ body: String) -> Bool {
            guard body.allSatisfy(\.isASCII) else { return false }
            // Anchors only where WebKit takes them: "^" first (or as a
            // negated set), "$" last.
            let inner = body.dropFirst().dropLast()
            if inner.contains("$") { return false }
            var previous = body.first ?? " "
            for character in inner {
                if character == "^" && previous != "[" { return false }
                previous = character
            }
            for banned in ["|", "{", "}", "\\d", "\\D", "\\w", "\\W", "\\s", "\\S", "\\b", "\\B", "(?", "*?", "+?"] where body.contains(banned) {
                return false
            }
            return true
        }
    }

    enum Types {
        static func everything(_ modern: Bool) -> Set<String> {
            ["image", "style-sheet", "script", "font", "media", "svg-document", "fetch", "websocket", "ping", "other",
             modern ? "child-document" : "document"]
        }

        static let map: [String: (Bool) -> Set<String>] = [
            "script": { _ in ["script"] },
            "image": { _ in ["image"] },
            "stylesheet": { _ in ["style-sheet"] }, "css": { _ in ["style-sheet"] },
            "xmlhttprequest": { _ in ["fetch"] }, "xhr": { _ in ["fetch"] },
            "subdocument": { $0 ? ["child-document"] : ["document"] }, "frame": { $0 ? ["child-document"] : ["document"] },
            "media": { _ in ["media"] }, "object": { _ in ["other"] },
            "font": { _ in ["font"] },
            "websocket": { _ in ["websocket"] },
            "ping": { _ in ["ping"] }, "beacon": { _ in ["ping"] },
            "other": { _ in ["other"] },
        ]
    }

    enum Sites {
        /// "a.com,~b.com,c.*,d.com>>" into the sites it is for, the sites it
        /// is not, the sites whose frames it is also for, and whether any
        /// site it is for could not be read (uBO's /regex/ sites).
        static func split(_ list: String) -> (positive: Set<String>, negative: Set<String>, ancestors: Set<String>, unread: Bool) {
            var positive = Set<String>(), negative = Set<String>(), ancestors = Set<String>()
            var unread = false
            for part in list.split(separator: ",") {
                var site = part.trimmingCharacters(in: .whitespaces).lowercased()
                let negated = site.hasPrefix("~")
                if negated { site.removeFirst() }
                let framed = site.hasSuffix(">>")
                if framed { site.removeLast(2) }
                let bare = site.hasSuffix(".*") ? String(site.dropLast(2)) : site
                guard !bare.isEmpty, bare.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
                    if !negated { unread = true }
                    continue
                }
                if negated { negative.insert(site) } else if framed { ancestors.insert(site) } else { positive.insert(site) }
            }
            return (positive, negative, ancestors, unread)
        }

        /// "site.*" as a pattern over the page's address.
        static func entityFilter(_ entity: String) -> String {
            let name = entity.dropLast(2).replacingOccurrences(of: ".", with: "\\.")
            return "^[a-z]+://([^/]*\\.)?" + name + "\\.[^/.]+(\\.[^/.]+)?[:/]"
        }
    }

    enum Selector {
        static let proceduralMarks = [":has-text(", ":-abp-", ":upward(", ":matches-css", ":xpath(", ":remove(", ":style(",
                                      ":watch-attr(", ":min-text-length(", ":others(", ":matches-attr(", ":matches-media(",
                                      ":matches-path(", ":matches-prop(", ":shadow", ":if(", ":if-not(", ":nth-ancestor(",
                                      ":contains(", ":remove-attr(", ":remove-class("]

        static func procedural(_ body: String) -> Bool { proceduralMarks.contains { body.contains($0) } }

        /// A selector WebKit is likely to read: no procedural pieces, balanced.
        static func plausible(_ body: String) -> Bool {
            guard !body.isEmpty, body.count < 1500, !procedural(body), !body.contains("{"), !body.contains("}"),
                  !body.hasPrefix("^") else { return false }
            var depth = 0, brackets = 0, quote: Character?
            for character in body {
                if let open = quote { if character == open { quote = nil }; continue }
                switch character {
                case "\"", "'": quote = character
                case "(": depth += 1
                case ")": depth -= 1
                case "[": brackets += 1
                case "]": brackets -= 1
                default: break
                }
                if depth < 0 || brackets < 0 { return false }
            }
            return depth == 0 && brackets == 0 && quote == nil
        }

        /// Selectors for one rule. WebKit rejects a rule whose only selector it
        /// cannot read, and the whole list with it; one it can always read is
        /// added, so a stray one costs that selector alone.
        static func list(_ selectors: [String]) -> String {
            (selectors + ["search-shield-guard"]).joined(separator: ", ")
        }
    }

    enum Scriptlet {
        /// uBO lets only its own lists run these; the ones here are safe to.
        static let trustedAllowed: Set<String> = []

        /// "name, 'a', b\, c" into ["name", "a", "b, c"].
        static func arguments(_ inside: String) -> [String] {
            var out: [String] = []
            var current = ""
            var escaped = false
            var quote: Character?
            for character in inside {
                if escaped { current.append(character); escaped = false; continue }
                if character == "\\" { escaped = true; current.append(character); continue }
                if let open = quote {
                    if character == open { quote = nil }
                    current.append(character)
                    continue
                }
                if (character == "'" || character == "\"") && current.trimmingCharacters(in: .whitespaces).isEmpty {
                    quote = character
                    current.append(character)
                    continue
                }
                if character == "," {
                    out.append(clean(current))
                    current = ""
                    continue
                }
                current.append(character)
            }
            out.append(clean(current))
            return out
        }

        private static func clean(_ raw: String) -> String {
            var value = raw.trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "'" || first == "\"" {
                value = String(value.dropFirst().dropLast())
            }
            return value.replacingOccurrences(of: "\\,", with: ",")
        }
    }

    enum Preprocessor {
        /// uBO's !#if tokens, answered as a WebKit browser running uBO's
        /// lists: https://github.com/gorhill/uBlock/wiki/Static-filter-syntax#if-condition
        static let tokens: [String: Bool] = [
            "ext_ublock": true, "ext_ubol": false, "ext_devbuild": false, "env_safari": true,
            "env_chromium": false, "env_edge": false, "env_firefox": false, "env_mobile": false,
            "env_mv3": false, "env_legacy": false, "cap_html_filtering": false, "cap_user_stylesheet": true,
            "cap_ipaddress": false, "adguard": false, "adguard_app_windows": false, "adguard_ext_safari": false,
            "false": false, "true": true,
        ]

        static func holds(_ expression: String) -> Bool {
            var tokens = expression.replacingOccurrences(of: "(", with: " ( ").replacingOccurrences(of: ")", with: " ) ")
                .replacingOccurrences(of: "&&", with: " && ").replacingOccurrences(of: "||", with: " || ")
                .replacingOccurrences(of: "!", with: " ! ")
                .split(separator: " ").map(String.init)
            return or(&tokens)
        }

        private static func or(_ tokens: inout [String]) -> Bool {
            var value = and(&tokens)
            while tokens.first == "||" { tokens.removeFirst(); let right = and(&tokens); value = value || right }
            return value
        }

        private static func and(_ tokens: inout [String]) -> Bool {
            var value = unary(&tokens)
            while tokens.first == "&&" { tokens.removeFirst(); let right = unary(&tokens); value = value && right }
            return value
        }

        private static func unary(_ tokens: inout [String]) -> Bool {
            guard let token = tokens.first else { return false }
            tokens.removeFirst()
            switch token {
            case "!": return !unary(&tokens)
            case "(":
                let value = or(&tokens)
                if tokens.first == ")" { tokens.removeFirst() }
                return value
            default: return self.tokens[token] ?? false
            }
        }
    }
}
