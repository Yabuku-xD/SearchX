import Foundation

// Run from the repository root:
// swiftc Sources/Search/Session.swift Tests/SessionCheck.swift -o /tmp/search-session-check && /tmp/search-session-check
enum Store {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    static func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
    static func quarantine(_ file: URL) { fatalError("Unexpected invalid session: \(file)") }
}

enum Space {
    static let firstID = UUID()
}

/// Stood in for the app's own (see TabGroup.swift): the session only ever
/// holds the id, so the isolated check needs nothing but the type.
struct TabGroup: Codable, Equatable {
    var id: UUID
    var name: String
    var collapsed: Bool
}

@main
struct SessionCheck {
    static func main() throws {
        defer { try? FileManager.default.removeItem(at: Store.folder) }
        for index in 0..<1_000 {
            Session.write(.init(windows: [.init(id: nil, tabs: [.init(url: "https://example.com/\(index)", title: "Older")], active: 0)]))
        }
        let final = Session.Shape(windows: [.init(id: nil, tabs: [
            .init(url: "https://example.com/kept", title: "Kept", pin: "K", name: "Named", groupID: nil),
            .init(url: "https://example.com/active", title: "Active")
        ], active: 1)])
        Session.write(final)
        let restored = Session.read().windows[0]
        assert(restored.tabs.map(\.url) == final.windows[0].tabs.map(\.url))
        assert(restored.active == 1)
        assert(restored.tabs[0].pin == "K" && restored.tabs[0].name == "Named" && restored.tabs[0].groupID == nil)
        let deleted = UUID()
        Session.write(space: deleted, final)
        Session.erase(space: deleted)
        assert(!FileManager.default.fileExists(atPath: Store.file("session-\(deleted.uuidString).json").path))
        print("PASS: final session wins, active tab and metadata restore, deleted spaces stay deleted")
    }
}
