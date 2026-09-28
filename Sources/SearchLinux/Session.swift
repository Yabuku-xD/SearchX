import Foundation

// What was open last time, in the same shape the Mac keeps it in: the
// addresses, their names, and which one you were looking at.

enum Session {
    struct Entry: Codable {
        var url: String
        var title: String
    }

    struct Shape: Codable {
        var tabs: [Entry]
        var active: Int
    }

    private static let file = Folder.file("session.json")
    private static let writer = DispatchQueue(label: "search.session", qos: .utility)
    // Accessed only by writer, including from the final synchronous flush.
    private static var pending: Shape?
    private static var scheduled: DispatchWorkItem?

    static func read() -> Shape {
        guard let data = try? Data(contentsOf: file),
              let shape = try? JSONDecoder().decode(Shape.self, from: data)
        else { return Shape(tabs: [], active: 0) }
        return shape
    }

    /// Match the Mac's 1.2-second coalescing window. GLib need not drain
    /// Dispatch's main queue: scheduling and IO stay on this serial worker.
    static func write(_ shape: Shape) {
        writer.async {
            pending = shape
            guard scheduled == nil else { return }
            let work = DispatchWorkItem { commit() }
            scheduled = work
            writer.asyncAfter(deadline: .now() + 1.2, execute: work)
        }
    }

    private static func commit() {
        scheduled = nil
        guard let shape = pending else { return }
        pending = nil
        guard let data = try? JSONEncoder().encode(shape) else { return }
        try? data.write(to: file, options: .atomic)
    }

    static func flush() {
        writer.sync {
            scheduled?.cancel()
            commit()
        }
    }
}
