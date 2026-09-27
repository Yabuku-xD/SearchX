import AppKit
import UniformTypeIdentifiers

// File › Share…: the page, wherever the Mac would send it — Mail, Messages,
// AirDrop, Notes, anything else registered. Safari has a button for this on
// its toolbar; this app has no toolbar, so it lives in the File menu instead.

extension Browser {
    /// With no button to open under, the picker opens from the top right
    /// corner of the page, about where Safari keeps its Share button: just
    /// under the row when the tabs are across the top, and beside the
    /// column's page otherwise. The window's own corner is the fallback.
    func share() {
        guard key?.active?.showsPage == true, let url = key?.active?.address, let window = keyHost,
              let view = key?.active?.built.flatMap({ $0.window === window ? $0 : nil }) ?? window.contentView
        else { return }
        // A few points in from the corner, so the arrow points at the page
        // rather than at its edge. Flipped or not, the picker hangs below.
        let inset: CGFloat = 12
        let y = view.isFlipped ? inset : view.bounds.maxY - inset
        let anchor = NSRect(x: view.bounds.maxX - inset, y: y, width: 1, height: 1)
        NSSharingServicePicker(items: [url]).show(relativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }
}

extension WindowModel {
    func captureElement(to destination: ElementCapture.Destination) {
        guard let tab = active, tab.showsPage, tab.built != nil else { return }
        for other in tabs where other.captureDestination != nil { cancelElementCapture(other) }
        if profile.veiling {
            tab.stopPicking()
            profile.veiling = false
        }
        tab.captureDestination = destination
        ElementPicker.start(in: tab)
        profile.announce("Click an element to capture it. Escape cancels.")
    }

    func cancelElementCapture(_ tab: Tab) {
        guard tab.captureDestination != nil else { return }
        tab.captureDestination = nil
        if tab.built != nil { ElementPicker.stop(in: tab) }
    }

    func finishElementCapture(_ tab: Tab, rect: CGRect) {
        guard tab.owner === self, let destination = tab.captureDestination,
              let web = tab.built else { return }
        let address = tab.address
        cancelElementCapture(tab)
        Task { @MainActor [weak self, weak tab] in
            guard let image = await ElementCapture.capture(rect, in: web),
                  let self, let tab, tab.owner === self,
                  tab.built === web, tab.address == address else { return }
            switch destination {
            case .clipboard:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
                profile.announce("Element image copied")
            case .file:
                guard let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                      let host = profile.host(of: self) else {
                    profile.announce("Couldn't create the element image")
                    return
                }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = "Element.png"
                panel.beginSheetModal(for: host) { [weak self] result in
                    guard result == .OK, let url = panel.url else { return }
                    do {
                        try png.write(to: url, options: .atomic)
                        self?.profile.announce("Element image saved")
                    } catch {
                        self?.profile.announce("Couldn't save the element image: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}
