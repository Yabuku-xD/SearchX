import AppKit
import SwiftUI

// Web panels, Vivaldi's: a site kept docked on the right beside the page you
// are reading — a chat, mail, a calendar, a to-do list — in the column an
// extension's side panel uses (see ExtensionPanel.swift).
//
// A panel is a page like any tab, with the blocker, the passwords and the
// sign-ins a tab has, only not in the row. It is made when it is opened and
// let go of when it is closed, so a list of ten panels costs nothing until
// one is looked at, and only that one while it is. Mobile layout asks the
// site for the page it gives a phone, which suits a narrow column.

struct WebPanelSite: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: String
    var name: String
    var mobile = false

    var address: URL? { URL(string: url) }
    var host: String { address?.host()?.lowercased() ?? "" }
}

/// The panels kept, in the order they were added. Only this list is kept;
/// no page is.
@MainActor
final class WebPanels: ObservableObject {
    static let shared = WebPanels()

    @Published private(set) var sites: [WebPanelSite]

    private init() {
        sites = Store.settings.data(forKey: "panels.web")
            .flatMap { try? JSONDecoder().decode([WebPanelSite].self, from: $0) } ?? []
    }

    /// The site as a panel, or the one already kept for the same address.
    @discardableResult
    func add(_ url: URL, name: String) -> WebPanelSite {
        if let kept = sites.first(where: { $0.url == url.absoluteString }) { return kept }
        let site = WebPanelSite(url: url.absoluteString, name: name.isEmpty ? Address.pretty(url) : name)
        sites.append(site)
        save()
        return site
    }

    func remove(_ id: UUID) {
        sites.removeAll { $0.id == id }
        save()
    }

    func setMobile(_ id: UUID, _ on: Bool) {
        guard let index = sites.firstIndex(where: { $0.id == id }) else { return }
        sites[index].mobile = on
        save()
    }

    func site(_ id: UUID) -> WebPanelSite? { sites.first { $0.id == id } }

    private func save() {
        if sites.isEmpty {
            Store.settings.removeObject(forKey: "panels.web")
        } else {
            Store.settings.set(try? JSONEncoder().encode(sites), forKey: "panels.web")
        }
    }
}

/// One open web panel: the site, and the tab showing it outside the row.
@MainActor
final class WebPanel: DockedPage {
    let siteID: UUID
    let tab: Tab
    let name: String

    /// What a phone's Safari says it is, for a site's mobile layout.
    static let mobileAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    var id: String { WebPanel.id(siteID) }
    static func id(_ site: UUID) -> String { "web:" + site.uuidString }
    var icon: NSImage? { tab.icon }
    var view: NSView { tab.web }

    init?(site: WebPanelSite, window: WindowModel) {
        guard let url = site.address else { return nil }
        siteID = site.id
        name = site.name
        tab = window.makeTab()
        tab.enter(window)
        if site.mobile { tab.web.customUserAgent = WebPanel.mobileAgent }
        tab.go(to: url)
    }

    /// The panel closed: its page goes with it.
    func forget() { tab.close() }

    func setMobile(_ on: Bool) {
        tab.web.customUserAgent = on ? WebPanel.mobileAgent : nil
        tab.web.reload()
    }
}

extension WindowModel {
    /// The site in the panel, or the panel put away if it is the one open.
    func togglePanel(_ site: WebPanelSite) {
        if panel?.id == WebPanel.id(site.id) { return closePanel() }
        closePanel()
        panelHeld = false
        guard let opened = WebPanel(site: site, window: self) else { return }
        withAnimation(Motion.settle) { panel = opened }
    }

    /// The tab's site kept as a panel, and opened there. The tab stays.
    func openInPanel(_ tab: Tab) {
        guard tab.showsPage, let url = tab.address else { return }
        let site = WebPanels.shared.add(url, name: tab.title)
        if panel?.id == WebPanel.id(site.id) { return }
        togglePanel(site)
    }

    /// The panel's page moved into the row, in front, as it is.
    func panelToTab() {
        guard let web = panel as? WebPanel else { return }
        web.tab.web.customUserAgent = nil
        withAnimation(Motion.quick) { panel = nil }
        insert(web.tab, at: placeForNew())
        select(web.tab)
    }

    func setPanelMobile(_ on: Bool) {
        guard let web = panel as? WebPanel else { return }
        WebPanels.shared.setMobile(web.siteID, on)
        web.setMobile(on)
    }
}

/// A kept panel's button, among the column's doors: the site's own icon,
/// lit while its panel is open.
struct PanelDoor: View {
    @ObservedObject var window: WindowModel
    let site: WebPanelSite

    @State private var hovering = false

    var body: some View {
        let open = window.panel?.id == WebPanel.id(site.id)
        Button { window.togglePanel(site) } label: {
            SiteMark(host: site.host, letter: String(site.name.prefix(1)).uppercased(), size: 14, dim: !open && !hovering)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(open ? Palette.wash : (hovering ? Palette.hover : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(Press())
        .help(site.name)
        .accessibilityLabel("\(site.name) panel")
        .accessibilityValue(open ? "Open" : "Closed")
        .onHover { hovering = $0 }
        .contextMenu {
            Button(site.mobile ? "Use Desktop Layout" : "Use Mobile Layout") {
                WebPanels.shared.setMobile(site.id, !site.mobile)
                if open { window.setPanelMobile(!site.mobile) }
            }
            Divider()
            Button("Remove Panel") {
                if open { window.closePanel() }
                WebPanels.shared.remove(site.id)
            }
        }
    }
}

/// Every kept panel's door, in the order they were kept.
struct PanelDoors: View {
    @ObservedObject var window: WindowModel
    @ObservedObject private var panels = WebPanels.shared

    var body: some View {
        ForEach(panels.sites) { site in
            PanelDoor(window: window, site: site)
        }
    }
}

/// The web panel's own choices, behind its head's ellipsis.
struct WebPanelMenu: View {
    @ObservedObject var window: WindowModel
    let panel: WebPanel
    @ObservedObject private var panels = WebPanels.shared

    var body: some View {
        let mobile = panels.site(panel.siteID)?.mobile ?? false
        Menu {
            Button(mobile ? "Use Desktop Layout" : "Use Mobile Layout") { window.setPanelMobile(!mobile) }
            Button("Open as Tab") { window.panelToTab() }
            Divider()
            Button("Remove Panel") {
                window.closePanel()
                panels.remove(panel.siteID)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Panel options")
        .accessibilityLabel("Panel options")
    }
}
