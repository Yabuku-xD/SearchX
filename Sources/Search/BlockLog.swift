import SwiftUI
import WebKit

// What the blocker did on a tab, as uBO's logger shows it: every load a list
// blocked, the cookies it kept off, what it upgraded or rewrote, the
// addresses cleaned of tracking and the documents refused for a header — and,
// while the log is open, what the page loaded that nothing stopped. WebKit
// says which list acted, not which line of it.

@MainActor
final class BlockLog: ObservableObject {
    enum Kind: String {
        case blocked, cookies, upgraded, redirected, headers, header, cleaned, allowed
        var label: String {
            switch self {
            case .blocked: "Blocked"
            case .cookies: "Cookies blocked"
            case .upgraded: "Made secure"
            case .redirected: "Redirected"
            case .headers: "Headers changed"
            case .header: "Refused for a header"
            case .cleaned: "Tracking removed"
            case .allowed: "Allowed"
            }
        }
        var symbol: String {
            switch self {
            case .blocked, .header: "xmark.circle"
            case .cookies: "hand.raised"
            case .upgraded: "lock"
            case .redirected, .headers: "arrow.triangle.2.circlepath"
            case .cleaned: "scissors"
            case .allowed: "checkmark.circle"
            }
        }
        var stopped: Bool { self != .allowed }
    }

    struct Entry: Identifiable {
        let id = UUID()
        let at = Date()
        let kind: Kind
        let url: URL
        let source: String
        init(kind: Kind, url: URL, source: String) { self.kind = kind; self.url = url; self.source = source }
        var host: String { url.host()?.lowercased() ?? url.absoluteString }
    }

    /// Newest last, the last few hundred.
    @Published private(set) var entries: [Entry] = []
    private static let most = 400
    /// What the page loaded, by address, so a second look adds only what's new.
    private var seen = Set<String>()

    func add(_ entry: Entry) {
        // WebKit tells of one load twice when the page's preloader asked for
        // it first; one line is what happened.
        if entries.suffix(30).contains(where: { $0.kind == entry.kind && $0.url == entry.url && $0.source == entry.source
            && entry.at.timeIntervalSince($0.at) < 2 }) { return }
        entries.append(entry)
        if entries.count > BlockLog.most { entries.removeFirst(entries.count - BlockLog.most) }
    }

    func clear() {
        entries.removeAll()
        seen.removeAll()
    }

    /// Another look at what the page itself loaded (its resource timing),
    /// only while the log is open.
    func allowed(_ addresses: [String]) {
        for address in addresses where seen.insert(address).inserted {
            if let url = URL(string: address), ["http", "https"].contains(url.scheme ?? "") {
                add(Entry(kind: .allowed, url: url, source: ""))
            }
        }
    }

    /// A rule list's name, as the log says it.
    static func name(of identifier: String) -> String {
        if identifier.hasPrefix(OwnFilters.prefix + "rules") { return "My rules" }
        if identifier.hasPrefix(OwnFilters.prefix) { return "My filters" }
        if identifier.hasPrefix(Filters.prefix + "ads") { return "uBlock filters & EasyList" }
        if identifier.hasPrefix(Filters.prefix + "privacy") { return "Privacy lists" }
        if identifier.hasPrefix(Filters.prefix + "security") { return "Malicious sites list" }
        return "Built-in list"
    }

    /// The page's loads since the last look, from SearchX's own world.
    static let resources = "(function(){var n=window.__searchxSeen||0,l=performance.getEntriesByType('resource');window.__searchxSeen=l.length;return l.slice(n).map(function(e){return e.name;});})()"
}

/// Which part of the blocker panel is up.
enum BlockerPage: String, CaseIterable, Identifiable {
    case log, filters, rules
    var id: String { rawValue }
    var title: String {
        switch self {
        case .log: "Log"
        case .filters: "My filters"
        case .rules: "My rules"
        }
    }
}
struct BlockerPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var own: OwnFilters

    /// One height for every page, so turning from the log to your filters
    /// doesn't move the panel under the pointer.
    private static let height: CGFloat = 468

    var body: some View {
        Plate("Blocker", width: 680, close: { browser.blockering = nil }) {
            VStack(alignment: .leading, spacing: 16) {
                // The page is the browser's to say, so Settings or the menu
                // can turn to another while this is up.
                Segmented(options: BlockerPage.allCases.map { ($0, $0.title) },
                          selection: Binding(get: { browser.blockering ?? .log }, set: { browser.blockering = $0 }))
                Group {
                    switch browser.blockering ?? .log {
                    case .log:
                        if let tab = browser.key?.active { LogPage(browser: browser, tab: tab, log: tab.blockLog) }
                        else { Card { Nothing("No page is open.") } }
                    case .filters: FiltersPage(own: own)
                    case .rules: RulesPage(own: own)
                    }
                }
                .frame(height: BlockerPanel.height, alignment: .top)
            }
        } foot: {
            EmptyView()
        }
    }
}

// MARK: - the log

private struct LogPage: View {
    @ObservedObject var browser: Browser
    let tab: Tab
    @ObservedObject var log: BlockLog
    @State private var query = ""
    @State private var only: Show = .all
    @FocusState private var searching: Bool

    enum Show: String, CaseIterable { case all, stopped, allowed }

    private var site: String { tab.address?.host()?.lowercased() ?? "" }

    private var shown: [BlockLog.Entry] {
        log.entries.reversed().filter { entry in
            switch only {
            case .all: break
            case .stopped: if !entry.kind.stopped { return false }
            case .allowed: if entry.kind.stopped { return false }
            }
            return query.isEmpty || entry.url.absoluteString.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Hunt(text: $query, prompt: "Filter addresses", focus: $searching)
                Segmented(options: [(Show.all, "All"), (Show.stopped, "Stopped"), (Show.allowed, "Allowed")], selection: $only)
                    .fixedSize()
            }
            if log.entries.isEmpty {
                // What belongs here, and the one thing that fills it.
                Card {
                    VStack(spacing: 10) {
                        Nothing("Nothing yet. Reload the page to see everything it loads and what was stopped.")
                        Pill("Reload page", filled: true) { browser.key?.reload() }
                    }
                    .padding(.bottom, 14)
                }
            } else if shown.isEmpty {
                Card { Nothing("Nothing matches “\(query)”.") }
            } else {
                ScrollView {
                    Card {
                        ForEach(Array(shown.prefix(300).enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Rule() }
                            Row(entry: entry, site: site, own: OwnFilters.shared)
                        }
                    }
                    .padding(.bottom, 2)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                // A count that changes as the page loads keeps its width.
                (Text("\(log.entries.filter { $0.kind.stopped }.count)").monospacedDigit()
                    + Text(" stopped on \(site.isEmpty ? "this page" : site)"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Pill("Clear log") { log.clear() }
                    .disabled(log.entries.isEmpty)
                Pill("Reload page") { browser.key?.reload() }
            }
            .padding(.top, 8)
        }
        // What the page loads, looked at once a second while this is up.
        .task(id: ObjectIdentifier(tab)) {
            while !Task.isCancelled {
                if let web = tab.built {
                    let names = try? await web.evaluateJavaScript(BlockLog.resources, in: nil, contentWorld: Web.world) as? [String]
                    log.allowed(names ?? [])
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private struct Row: View {
        let entry: BlockLog.Entry
        let site: String
        @ObservedObject var own: OwnFilters
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                // Stopped or not, said by the shape and the word, not only the colour.
                Image(systemName: entry.kind.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(entry.kind.stopped ? Palette.ink : Palette.muted)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.host)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(entry.url.path.isEmpty ? "/" : entry.url.path)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(entry.kind.label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(entry.kind.stopped ? Palette.ink : Palette.muted)
                    if !entry.source.isEmpty {
                        Text(entry.source)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                    }
                }
                // The same choices as the right-click, where the pointer
                // already is: found without knowing to right-click.
                Menu { actions } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hovering ? 1 : 0)
                .accessibilityLabel("Actions for \(entry.host)")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // The whole address, which the line shortens.
            .help(entry.url.absoluteString)
            .contextMenu { actions }
        }

        @ViewBuilder private var actions: some View {
            let host = entry.host
            if !site.isEmpty, host != site {
                Button("Block \(host) on \(site)") { Task { await own.set(.init(source: site, destination: host, type: "*", action: .block)) } }
                Button("Allow \(host) on \(site)") { Task { await own.set(.init(source: site, destination: host, type: "*", action: .allow)) } }
            }
            Button("Block \(host) Everywhere") { Task { await own.set(.init(source: "*", destination: host, type: "*", action: .block)) } }
            if !site.isEmpty, own.rule(source: site, destination: host, type: "*") != .none {
                Button("Remove My Rule for \(host) on \(site)") { Task { await own.set(.init(source: site, destination: host, type: "*", action: .none)) } }
            }
            Divider()
            Button("Add Filter “||\(host)^”") { Task { await own.add(filter: "||\(host)^") } }
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.url.absoluteString, forType: .string)
            }
        }
    }
}

// MARK: - your filters and rules

private struct FiltersPage: View {
    @ObservedObject var own: OwnFilters
    @State private var draft = ""
    @State private var loaded = false

    var body: some View {
        Editor(
            text: $draft,
            label: "My filters",
            hint: "uBlock Origin’s syntax, one filter a line. For example youtube.com##ytd-rich-shelf-renderer:has-text(Shorts)",
            status: "\(own.report.filters) filter\(own.report.filters == 1 ? "" : "s") · never on sign-in, passkey or payment pages",
            problem: problem,
            save: "Save filters",
            apply: { await own.save(filters: draft) }
        )
        .onAppear { if !loaded { draft = own.filters; loaded = true } }
    }

    private var problem: String? {
        if let trouble = own.report.trouble { return trouble }
        let lines = own.report.skipped
        guard !lines.isEmpty else { return nil }
        return (lines.count == 1 ? "Line " : "Lines ") + lines.prefix(8).map(String.init).joined(separator: ", ")
            + (lines.count == 1 ? " isn’t a filter SearchX understands" : " aren’t filters SearchX understands")
    }
}

private struct RulesPage: View {
    @ObservedObject var own: OwnFilters
    @State private var draft = ""
    @State private var loaded = false

    var body: some View {
        Editor(
            text: $draft,
            label: "My rules",
            hint: "One rule a line, as source destination type action. For example example.com * 3p-script block. Types: * 3p 3p-script 3p-frame 1p-script inline-script image. Actions: block, allow, noop.",
            status: "\(own.report.rules) rule\(own.report.rules == 1 ? "" : "s") · allow rules reach uBlock Origin’s lists after a short compile",
            problem: problem,
            save: "Save rules",
            apply: { await own.save(rules: draft) }
        )
        .onAppear { if !loaded { draft = own.rules; loaded = true } }
    }

    private var problem: String? {
        if let trouble = own.report.trouble { return trouble }
        let lines = own.report.ruleErrors
        guard !lines.isEmpty else { return nil }
        return (lines.count == 1 ? "Line " : "Lines ") + lines.prefix(8).map(String.init).joined(separator: ", ")
            + (lines.count == 1 ? " isn’t a rule SearchX understands" : " aren’t rules SearchX understands")
    }
}

private struct Editor: View {
    @Binding var text: String
    let label: String
    let hint: String
    let status: String
    /// What's wrong with what was saved, said beside the editor it's about.
    let problem: String?
    let save: String
    let apply: () async -> Void

    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(hint)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                .padding(8)
                .frame(maxHeight: .infinity)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(problem == nil ? .clear : Palette.muted.opacity(0.6), lineWidth: 1))
                .accessibilityLabel(label)
                .accessibilityHint(problem ?? "")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.ink)
                    }
                    Text(status)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                }
                Spacer()
                // Said where it was pressed: the button itself answers.
                ZStack {
                    if saved {
                        Label("Saved", systemImage: "checkmark")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .transition(Swap.it)
                    } else {
                        Pill(save, filled: true) {
                            Task {
                                await apply()
                                withAnimation(Motion.easeOut(0.18)) { saved = true }
                                try? await Task.sleep(for: .seconds(1.4))
                                withAnimation(Motion.easeOut(0.18)) { saved = false }
                            }
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        .help(save + "   ⌘↩")
                        .transition(Swap.it)
                    }
                }
            }
        }
    }
}

/// One thing becoming another in the same place: the new one grows in from
/// a quarter, unblurs and fades up, the old one the reverse.
private struct Swap: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content.scaleEffect(on ? 1 : 0.25).opacity(on ? 1 : 0).blur(radius: on ? 0 : 4)
    }
    static var it: AnyTransition {
        Motion.reduced ? .opacity : .modifier(active: Swap(on: false), identity: Swap(on: true))
    }
}

