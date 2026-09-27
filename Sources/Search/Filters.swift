import Foundation
import WebKit

// uBlock Origin's default filter lists, kept up to date and compiled into
// WebKit's own blocker (see FilterCompiler), beside the few rules Search
// ships with (ShieldRules). uBO's default setup:
// github.com/gorhill/uBlock/wiki/Blocking-mode — its own filters, badware,
// privacy, quick fixes and unbreak lists, EasyList, EasyPrivacy, Peter
// Lowe's ad servers and the online malicious URL list.
//
// Fetched straight from where uBO fetches them, without cookies, every four
// days as uBO does, and only when they have changed. Nothing about the pages
// you visit goes with the request. Compiling takes WebKit tens of seconds for
// this many rules, so it happens in the background and only when a list
// changed; every other launch reuses the compiled lists from WebKit's store.

@MainActor
final class Filters: ObservableObject {
    static let shared = Filters()

    struct Source {
        let id: String
        let title: String
        let group: String
        let urls: [String]
    }

    nonisolated static let sources: [Source] = [
        Source(id: "ublock-filters", title: "uBlock filters", group: "ads", urls: [
            "https://ublockorigin.github.io/uAssets/filters/filters.min.txt",
            "https://cdn.jsdelivr.net/gh/uBlockOrigin/uAssets@latest/filters/filters.min.txt"]),
        Source(id: "ublock-badware", title: "uBlock filters – Badware risks", group: "ads", urls: [
            "https://ublockorigin.github.io/uAssets/filters/badware.min.txt",
            "https://cdn.jsdelivr.net/gh/uBlockOrigin/uAssets@latest/filters/badware.min.txt"]),
        Source(id: "ublock-quick-fixes", title: "uBlock filters – Quick fixes", group: "ads", urls: [
            "https://ublockorigin.github.io/uAssets/filters/quick-fixes.min.txt",
            "https://cdn.jsdelivr.net/gh/uBlockOrigin/uAssets@latest/filters/quick-fixes.min.txt"]),
        Source(id: "ublock-unbreak", title: "uBlock filters – Unbreak", group: "ads", urls: [
            "https://ublockorigin.github.io/uAssets/filters/unbreak.min.txt",
            "https://cdn.jsdelivr.net/gh/uBlockOrigin/uAssets@latest/filters/unbreak.min.txt"]),
        Source(id: "easylist", title: "EasyList", group: "ads", urls: [
            "https://ublockorigin.github.io/uAssets/thirdparties/easylist.txt",
            "https://easylist.to/easylist/easylist.txt"]),
        Source(id: "peter-lowe", title: "Peter Lowe’s Ad and tracking server list", group: "ads", urls: [
            "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=1&mimetype=plaintext"]),
        Source(id: "ublock-privacy", title: "uBlock filters – Privacy", group: "privacy", urls: [
            "https://ublockorigin.github.io/uAssets/filters/privacy.min.txt",
            "https://cdn.jsdelivr.net/gh/uBlockOrigin/uAssets@latest/filters/privacy.min.txt"]),
        Source(id: "easyprivacy", title: "EasyPrivacy", group: "privacy", urls: [
            "https://ublockorigin.github.io/uAssets/thirdparties/easyprivacy.txt",
            "https://easylist.to/easylist/easyprivacy.txt"]),
        Source(id: "urlhaus", title: "Online Malicious URL Blocklist", group: "security", urls: [
            "https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-ag-online.txt",
            "https://curbengh.github.io/malware-filter/urlhaus-filter-ag-online.txt"]),
    ]

    /// How often the lists are looked at again: uBO's own default.
    static let freshness: TimeInterval = 4 * 24 * 3600

    struct Status: Equatable {
        var updated: Date?
        var rules = 0
        var scriptlets = 0
        var working = false
        var trouble: String?
    }

    @Published private(set) var status = Status()
    private(set) var lists: [WKContentRuleList] = []
    private(set) var table = FilterCompiler.ScriptletTable()
    private(set) var popupHosts = Set<String>()
    /// Goes up whenever a new set of lists is in place, for open pages to
    /// be given them.
    @Published private(set) var generation = 0
    private var started = false

    private struct Manifest: Codable {
        var identifiers: [String]
        var table: FilterCompiler.ScriptletTable
        var popupHosts: [String]
        var counts: [String: Int]
        var updated: Date
        var tags: [String: String]
    }

    nonisolated static let prefix = "office-filters-"
    private var folder: URL { Store.file("filters") }
    private var manifestFile: URL { folder.appendingPathComponent("compiled.json") }
    /// The compiled lists live with the profile's other filter files, where
    /// the compiling process (FilterWorker) can write them too.
    private var storeFolder: URL { folder.appendingPathComponent("rules", isDirectory: true) }
    private var store: WKContentRuleListStore? { WKContentRuleListStore(url: storeFolder) }

    /// At launch: the lists compiled last time, then a look for newer ones
    /// if they are due.
    func start() {
        guard !started else { return }
        started = true
        let file = manifestFile
        Task.detached(priority: .utility) {
            let manifest = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
            await MainActor.run { Filters.shared.adopt(manifest) }
        }
    }

    private func adopt(_ manifest: Manifest?) {
        guard let manifest, let store else {
            Task { await later() }
            return
        }
        Task {
            guard let found = await Filters.lookUp(manifest.identifiers, in: store) else {
                await later(force: true)
                return
            }
            install(found, manifest)
            if Date().timeIntervalSince(manifest.updated) > Filters.freshness { await later() }
        }
    }

    private func install(_ found: [WKContentRuleList], _ manifest: Manifest) {
        lists = found
        table = manifest.table
        popupHosts = Set(manifest.popupHosts)
        status.updated = manifest.updated
        status.rules = manifest.counts.filter { $0.key.hasPrefix("rules-") }.values.reduce(0, +)
        status.scriptlets = manifest.table.calls.count
        generation += 1
    }

    /// How long after launch the lists are fetched and compiled when they are
    /// due. Compiling peaks at a quarter of a gigabyte for about forty
    /// seconds; done at launch it landed on the moment everything else was
    /// starting. The built-in list blocks from the first second meanwhile,
    /// and Update now in Settings runs at once.
    static let settle: Duration = .seconds(45)

    private func later(force: Bool = false) async {
        try? await Task.sleep(for: Filters.settle)
        await update(force: force)
    }

    /// Fetches the lists that changed, has them compiled, puts them in place.
    func update(force: Bool = false) async {
        guard !status.working else { return }
        status.working = true
        status.trouble = nil
        defer { status.working = false }
        let folder = self.folder
        let previous = (try? Data(contentsOf: manifestFile)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
        let fetched = await Filters.fetch(into: folder, tags: previous?.tags ?? [:])
        guard fetched.present > 0 else {
            status.trouble = "The filter lists couldn’t be downloaded. The built-in list is still on."
            return
        }
        let missing = Filters.sources.count - fetched.present
        if !force, !fetched.changed, var kept = previous, !lists.isEmpty {
            kept.updated = Date()
            kept.tags = fetched.tags
            write(kept)
            status.updated = kept.updated
            return
        }
        let resultFile = folder.appendingPathComponent("result.json")
        guard await Filters.runWorker(lists: folder, store: storeFolder, result: resultFile),
              let data = try? Data(contentsOf: resultFile),
              let result = try? JSONDecoder().decode(FilterWorker.Result.self, from: data),
              let store, let found = await Filters.lookUp(result.identifiers, in: store) else {
            status.trouble = "The filter lists couldn’t be compiled. The built-in list is still on."
            return
        }
        try? FileManager.default.removeItem(at: resultFile)
        let manifest = Manifest(identifiers: result.identifiers, table: result.table, popupHosts: result.popupHosts,
                                counts: result.counts, updated: Date(), tags: fetched.tags)
        write(manifest)
        install(found, manifest)
        Filters.forget(keeping: Set(manifest.identifiers), in: store)
        if missing > 0 { status.trouble = "\(missing) of \(Filters.sources.count) lists couldn’t be downloaded; the rest are on." }
    }

    private func write(_ manifest: Manifest) {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: manifestFile, options: .atomic)
    }

    /// Search again, as FilterWorker, at low priority; true when it finished
    /// and wrote its result.
    private static func runWorker(lists: URL, store: URL, result: URL) async -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        try? FileManager.default.removeItem(at: result)
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = [FilterWorker.flag, lists.path, store.path, result.path]
            process.qualityOfService = .utility
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                done.resume(returning: finished.terminationReason == .exit && finished.terminationStatus == 0)
            }
            do { try process.run() } catch { done.resume(returning: false) }
        }
    }

    /// The compiled lists by name, or nil unless every one is there.
    private static func lookUp(_ identifiers: [String], in store: WKContentRuleListStore) async -> [WKContentRuleList]? {
        var found: [WKContentRuleList] = []
        for identifier in identifiers {
            guard let list = try? await store.contentRuleList(forIdentifier: identifier) else { return nil }
            found.append(list)
        }
        return found.isEmpty ? nil : found
    }

    /// Compiled lists from older rules, which WebKit would keep for good.
    private static func forget(keeping: Set<String>, in store: WKContentRuleListStore) {
        store.getAvailableContentRuleListIdentifiers { identifiers in
            for old in identifiers ?? [] where old.hasPrefix(prefix) && !keeping.contains(old) {
                store.removeContentRuleList(forIdentifier: old) { _ in }
            }
        }
    }

    nonisolated static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
        return String(hash, radix: 36)
    }

    /// Every list, from the network when it changed and from disk when it did
    /// not: how many are on disk afterwards, their tags, and whether any
    /// changed. A session without cookies, a cache or any identifier.
    nonisolated private static func fetch(into folder: URL, tags: [String: String]) async -> (present: Int, tags: [String: String], changed: Bool) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var present = 0
        var newTags = tags
        var changed = false
        await withTaskGroup(of: (String, Bool, String?, Bool).self) { group in
            for source in sources {
                group.addTask {
                    let file = folder.appendingPathComponent(source.id + ".txt")
                    let saved = try? Data(contentsOf: file)
                    for address in source.urls {
                        guard let url = URL(string: address) else { continue }
                        var request = URLRequest(url: url)
                        if saved != nil, let tag = tags[source.id] { request.setValue(tag, forHTTPHeaderField: "If-None-Match") }
                        guard let (data, response) = try? await session.data(for: request),
                              let http = response as? HTTPURLResponse else { continue }
                        if http.statusCode == 304, saved != nil { return (source.id, true, tags[source.id], false) }
                        guard http.statusCode == 200, data.count > 100, String(data: data, encoding: .utf8) != nil else { continue }
                        if data == saved { return (source.id, true, http.value(forHTTPHeaderField: "ETag"), false) }
                        guard (try? data.write(to: file, options: .atomic)) != nil else { continue }
                        return (source.id, true, http.value(forHTTPHeaderField: "ETag"), true)
                    }
                    // Offline or refused everywhere: last time's copy, if any.
                    return (source.id, saved != nil, tags[source.id], false)
                }
            }
            for await (id, here, tag, fresh) in group {
                if here { present += 1 }
                if let tag { newTags[id] = tag }
                changed = changed || fresh
            }
        }
        return (present, newTags, changed)
    }
}
