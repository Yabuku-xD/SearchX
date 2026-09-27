import SwiftUI

// Two pages side by side, when there is room for two.
//
// The window holds one tab row and one stage; the stage is what shows one
// page or two. A split is a pair of tabs already in the row (see Split.swift),
// so nothing about the tab row, the spaces or the session changes because a
// pair is on screen: the pair is remembered, and turning the feature off
// leaves the pair where it is for the next time it is on.

/// Two page hosts when there is room, or the one on screen when there is not.
struct SplitStage: View {
    @ObservedObject var browser: WindowModel
    /// The folded column or strip out over the pages, for the blur behind
    /// it: handed to the pane at its edge, or both for the strip.
    var overlay = PageOverlay()
    @State private var choosingTab = false

    static let minimumWidth: CGFloat = 560
    static let dividerWidth: CGFloat = 12

    var body: some View {
        GeometryReader { room in
            Group {
                if browser.profile.prefs.splitViews, let pending = browser.pendingSplit,
                   let right = browser.tabs.first(where: { $0.id == pending }) {
                    HStack(spacing: 0) {
                        emptyPane(except: pending)
                            .frame(width: max(0, (room.size.width - Self.dividerWidth) / 2))
                        Rectangle().fill(Palette.hairline).frame(width: 4).frame(width: Self.dividerWidth)
                        Page(tab: right, browser: browser.profile, overlay: overlay(column: 1, lastColumn: 1, row: 0, columns: 2))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if let pair = shownPair(in: room.size) {
                    panes(pages(of: pair), pair: pair, room: room.size)
                } else if let tab = browser.active {
                    Page(tab: tab, browser: browser.profile, overlay: overlay)
                } else {
                    Palette.ground
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { sizeChanged(room.size) }
            .onChange(of: room.size) { _, size in sizeChanged(size) }
            .onChange(of: browser.activePair?.members.count) { _, _ in sizeChanged(room.size) }
            .onChange(of: browser.activePair?.layout) { _, _ in sizeChanged(room.size) }
        }
    }

    /// Whether the stage has room for every pane of `pair` as it is laid out:
    /// no page narrower than 280 points or shorter than 180.
    static func fits(_ pair: SplitPair, in size: CGSize) -> Bool {
        let (columns, rows) = shape(pair)
        return size.width >= CGFloat(columns) * minimumWidth / 2 && size.height >= CGFloat(rows) * 180
    }

    /// The split in front, when every one of its tabs is here and the stage
    /// has room for them all.
    private func shownPair(in size: CGSize) -> SplitPair? {
        guard let pair = browser.activePair, Self.fits(pair, in: size),
              pages(of: pair).count == pair.members.count else { return nil }
        return pair
    }

    private func pages(of pair: SplitPair) -> [Tab] {
        pair.members.compactMap { id in browser.tabs.first { $0.id == id } }
    }

    /// Columns and rows for a pair: the grid is two across, and a third page
    /// takes the whole of the second row.
    static func shape(_ pair: SplitPair) -> (columns: Int, rows: Int) {
        let n = pair.members.count
        switch pair.layout {
        case .columns: return (n, 1)
        case .rows: return (1, n)
        case .grid: return n <= 2 ? (n, 1) : (2, 2)
        }
    }

    private func sizeChanged(_ size: CGSize) {
        let canShow = browser.activePair.map { Self.fits($0, in: size) } ?? (size.width >= Self.minimumWidth)
        guard browser.splitCanShow != canShow else { return }
        browser.splitCanShow = canShow
        if canShow { browser.wakeSplitPartner() }
    }

    private func shownFraction(_ fraction: Double, span: CGFloat) -> Double {
        let floor = max(0.25, min(0.5, 260 / max(1, span - Self.dividerWidth)))
        return min(1 - floor, max(floor, fraction))
    }

    /// The panes of a split, as its layout lays them out. Two share the stage
    /// by the divider's fraction; three and four share it equally.
    @ViewBuilder
    private func panes(_ pages: [Tab], pair: SplitPair, room: CGSize) -> some View {
        let (columns, rows) = Self.shape(pair)
        if pages.count == 2 {
            let across = pair.layout != .rows
            let span = (across ? room.width : room.height) - Self.dividerWidth
            let fraction = shownFraction(pair.fraction, span: span + Self.dividerWidth)
            let first = pane(pages[0], at: 0, of: pair, columns: columns, rows: rows)
            let second = pane(pages[1], at: 1, of: pair, columns: columns, rows: rows)
            if across {
                HStack(spacing: 0) {
                    first.frame(width: max(0, span * fraction))
                    SplitDivider(browser: browser, pair: pair, span: span + Self.dividerWidth, across: true, shownFraction: fraction)
                    second.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    first.frame(height: max(0, span * fraction))
                    SplitDivider(browser: browser, pair: pair, span: span + Self.dividerWidth, across: false, shownFraction: fraction)
                    second.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else if pair.layout == .grid {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    pane(pages[0], at: 0, of: pair, columns: columns, rows: rows)
                    Seam(across: true)
                    pane(pages[1], at: 1, of: pair, columns: columns, rows: rows)
                }
                Seam(across: false)
                HStack(spacing: 0) {
                    pane(pages[2], at: 2, of: pair, columns: columns, rows: rows)
                    if pages.count > 3 {
                        Seam(across: true)
                        pane(pages[3], at: 3, of: pair, columns: columns, rows: rows)
                    }
                }
            }
        } else if pair.layout == .rows {
            VStack(spacing: 0) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    if index > 0 { Seam(across: false) }
                    pane(page, at: index, of: pair, columns: columns, rows: rows)
                }
            }
        } else {
            HStack(spacing: 0) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    if index > 0 { Seam(across: true) }
                    pane(page, at: index, of: pair, columns: columns, rows: rows)
                }
            }
        }
    }

    /// One page of a split, with the edge that says which pane is in front.
    private func pane(_ tab: Tab, at index: Int, of pair: SplitPair, columns: Int, rows: Int) -> some View {
        let column = pair.layout == .rows ? 0 : (pair.layout == .grid ? index % 2 : index)
        let row = pair.layout == .rows ? index : (pair.layout == .grid ? index / 2 : 0)
        // A third page alone on the grid's second row spans it, so it is at
        // both edges.
        let last = pair.layout == .grid && pair.members.count == 3 && index == 2 ? columns - 1 : column
        return Page(tab: tab, browser: browser.profile, overlay: overlay(column: column, lastColumn: last, row: row, columns: columns))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                Rectangle()
                    .strokeBorder(tab.id == browser.activeID ? Palette.ink.opacity(0.35) : Palette.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel("Split pane \(index + 1) of \(pair.members.count): \(tab.label)")
    }

    /// The folded column's blur, for the panes along the edge it comes out
    /// over: the first column, the last, or the top row under the strip.
    private func overlay(column: Int, lastColumn: Int, row: Int, columns: Int) -> PageOverlay {
        switch overlay.edge {
        case .top: return row == 0 ? overlay : PageOverlay()
        case .leading: return column == 0 ? overlay : PageOverlay()
        case .trailing: return lastColumn == columns - 1 ? overlay : PageOverlay()
        }
    }

    /// The half waiting for its tab: a pair is started by dragging a tab into
    /// the stage or picking one here.
    private func emptyPane(except right: Tab.ID) -> some View {
        ZStack(alignment: .bottom) {
            Button { choosingTab = true } label: {
                VStack(spacing: 12) {
                    Image(systemName: "square.split.2x1")
                        .font(.system(size: 24, weight: .ultraLight))
                    Text("Drag a tab here")
                        .font(.system(size: 13))
                    Text("Or click to choose a tab")
                        .font(.system(size: 12))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .popover(isPresented: $choosingTab, arrowEdge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(browser.tabs.filter { $0.id != right && !$0.bench }) { tab in
                            Button(tab.label) {
                                choosingTab = false
                                browser.finishSplit(with: tab.id)
                            }
                            .buttonStyle(.plain)
                            .padding(10)
                        }
                    }
                }
                .frame(minWidth: 180, maxHeight: 300)
                .padding(8)
            }
            .accessibilityLabel("Choose a tab for the left split pane")
            Button("Cancel") { browser.pendingSplit = nil }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .padding(.bottom, 22)
        }
        .foregroundStyle(Palette.muted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
        .contentShape(Rectangle())
        .onDrop(of: [SplitDrag.type], isTargeted: nil) { providers in
            return SplitDrag.receive(providers) { browser.finishSplit(with: $0) }
        }
    }
}

/// The line between the panes of three or four: the same seam as two
/// have, only not for pulling, since they share the stage equally.
private struct Seam: View {
    let across: Bool

    var body: some View {
        if across {
            Rectangle().fill(Palette.hairline).frame(width: 4).frame(width: SplitStage.dividerWidth)
        } else {
            Rectangle().fill(Palette.hairline).frame(height: 4).frame(height: SplitStage.dividerWidth)
        }
    }
}

/// The seam two panes are divided by: drag it, or use the keyboard, and
/// the split moves underneath the pointer. Upright between columns, lying
/// down between rows.
private struct SplitDivider: View {
    @ObservedObject var browser: WindowModel
    let pair: SplitPair
    /// The stage along the way the panes share it, seam included.
    let span: CGFloat
    let across: Bool
    let shownFraction: Double

    @State private var start: Double?

    /// How far either pane may go, by the same rule the pane itself is
    /// drawn by, so the two never disagree about where the seam is.
    private var floor: Double {
        max(0.25, min(0.5, 260 / max(1, span - SplitStage.dividerWidth)))
    }

    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(width: across ? 4 : nil, height: across ? nil : 4)
            .frame(width: across ? SplitStage.dividerWidth : nil, height: across ? nil : SplitStage.dividerWidth)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if start == nil { start = shownFraction }
                    let moved = across ? value.translation.width : value.translation.height
                    let next = (start ?? shownFraction) + Double(moved / (span - SplitStage.dividerWidth))
                    browser.setSplitFraction(min(1 - floor, max(floor, next)), for: pair.id)
                }
                .onEnded { _ in
                    start = nil
                    let current = browser.splitPairs.first(where: { $0.id == pair.id })?.fraction ?? pair.fraction
                    browser.setSplitFraction(current, for: pair.id, save: true)
                })
            .help("Drag to resize split view")
            .onHover { over in
                if over { (across ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
            }
            .focusable()
            .accessibilityLabel("Split divider")
            .accessibilityValue("\(Int(shownFraction * 100)) percent \(across ? "left" : "top")")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: browser.setSplitFraction(min(1 - floor, shownFraction + 0.05), for: pair.id, save: true)
                case .decrement: browser.setSplitFraction(max(floor, shownFraction - 0.05), for: pair.id, save: true)
                @unknown default: break
                }
            }
    }
}
