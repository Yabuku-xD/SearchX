import CoreGraphics
import Foundation

// What was open last time. A list of addresses and their names, and which one
// you were looking at — nothing else, because everything else is either on the
// page or in the history file next door.
//
// One file per space, holding every window that was in that space. A file
// from before windows were kept decodes as one window, which is what it was.

enum Session {
    struct Split: Codable {
        var left: Int
        var right: Int
        var fraction: Double
        /// The third and fourth panes, and how they are laid out. Absent in a
        /// session written when a split was always two side by side.
        var extra: [Int]? = nil
        var layout: SplitLayout? = nil
    }

    struct Entry: Codable {
        var url: String
        var title: String
        var pin: String?
        var pinHome: String? = nil
        /// The name you gave the tab, when you gave it one.
        var name: String?
        /// The sidebar group this ordinary tab belongs to, if any.
        var groupID: UUID? = nil
        /// The container it keeps its sign-ins in, if any (see Containers).
        var container: UUID? = nil
    }

    /// One window's row: the tabs it held and which was on screen.
    struct WindowShape: Codable {
        /// Which window this was, so a restore can put the row back where it
        /// belongs. Nil in a file written before windows were kept.
        var id: UUID?
        var tabs: [Entry]
        var active: Int
        /// Where the window sat, when it was somewhere worth remembering.
        /// CGRect is not Codable, so it rides as four numbers.
        var frameBox: Frame?
        /// This space's tab groups, for the file this row came from. Nil on a
        /// session written before groups were kept.
        var groups: [TabGroup]?
        /// This window's split pairs. Nil on a session written before split
        /// view was kept.
        var splits: [Split]?

        /// A rectangle, as plain numbers, because CGRect is not Codable.
        struct Frame: Codable, Equatable {
            var x: Double
            var y: Double
            var width: Double
            var height: Double

            init(_ box: CGRect) {
                x = Double(box.origin.x)
                y = Double(box.origin.y)
                width = Double(box.width)
                height = Double(box.height)
            }

            var box: CGRect { CGRect(x: x, y: y, width: width, height: height) }
        }

        /// Every field, with the optional ones defaulted. A caller with no
        /// groups or splits of its own passes nothing for them.
        init(
            id: UUID? = nil,
            tabs: [Entry],
            active: Int,
            frame: CGRect? = nil,
            groups: [TabGroup]? = nil,
            splits: [Split]? = nil
        ) {
            self.id = id
            self.tabs = tabs
            self.active = active
            self.frame = frame
            self.groups = groups
            self.splits = splits
        }

        var frame: CGRect? {
            get { frameBox.map(\.box) }
            set { frameBox = newValue.map(Frame.init) }
        }

        private enum CodingKeys: String, CodingKey {
            case id, tabs, active, frameBox, groups, splits
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id)
            tabs = try c.decodeIfPresent([Entry].self, forKey: .tabs) ?? []
            active = try c.decodeIfPresent(Int.self, forKey: .active) ?? 0
            frameBox = try c.decodeIfPresent(Frame.self, forKey: .frameBox)
            groups = try c.decodeIfPresent([TabGroup].self, forKey: .groups)
            splits = try c.decodeIfPresent([Split].self, forKey: .splits)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(id, forKey: .id)
            try c.encode(tabs, forKey: .tabs)
            try c.encode(active, forKey: .active)
            try c.encodeIfPresent(frameBox, forKey: .frameBox)
            try c.encodeIfPresent(groups, forKey: .groups)
            try c.encodeIfPresent(splits, forKey: .splits)
        }
    }

    struct WindowLocation: Codable {
        let id: UUID
        let space: UUID
    }

    struct Shape: Codable {
        /// Stored only in session.json. Other space files hold the parked rows.
        var layout: [WindowLocation]?
        var windows: [WindowShape]

        init(windows: [WindowShape], layout: [WindowLocation]? = nil) {
            self.layout = layout
            self.windows = windows
        }

        private enum CodingKeys: String, CodingKey {
            case windows, tabs, active, groups, splits, layout
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            layout = try c.decodeIfPresent([WindowLocation].self, forKey: .layout)
            if let windows = try c.decodeIfPresent([WindowShape].self, forKey: .windows) {
                self.windows = windows
                return
            }
            // Legacy: one row, no window dimension. A file from after groups
            // and splits existed but before windows did carries them here, and
            // they belong to the single row it holds.
            let tabs = try c.decodeIfPresent([Entry].self, forKey: .tabs) ?? []
            let active = try c.decodeIfPresent(Int.self, forKey: .active) ?? 0
            let groups = try c.decodeIfPresent([TabGroup].self, forKey: .groups)
            let splits = try c.decodeIfPresent([Split].self, forKey: .splits)
            self.windows = [WindowShape(id: nil, tabs: tabs, active: active, groups: groups, splits: splits)]
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(windows, forKey: .windows)
            try c.encodeIfPresent(layout, forKey: .layout)
        }
    }

    /// Keep older background saves ahead of the final save made on quit: one
    /// serial queue, so a queued write cannot land after the last one.
    private static let writes = DispatchQueue(label: "search.session", qos: .utility)

    /// The first space's is the session there always was; each other space
    /// keeps its own beside it.
    private static func file(_ space: UUID) -> URL {
        Store.file(space == Space.firstID ? "session.json" : "session-\(space.uuidString).json")
    }

    static func erase(space: UUID) {
        guard space != Space.firstID else { return }
        writes.sync { try? FileManager.default.removeItem(at: file(space)) }
    }

    static func read(space: UUID = Space.firstID) -> Shape {
        // Behind any save still on its way, so a row just written is the
        // row read back.
        writes.sync { load(space: space) }
    }

    private static func load(space: UUID) -> Shape {
        let file = file(space)
        guard let data = try? Data(contentsOf: file) else { return Shape(windows: []) }
        guard let shape = try? JSONDecoder().decode(Shape.self, from: data) else {
            // A file that's there but won't decode is not the same as no
            // file: something wrote it, and overwriting it on the next save
            // without a trace is how yesterday's tabs actually disappear.
            Store.quarantine(file)
            return Shape(windows: [])
        }
        return shape
    }

    /// Every save goes onto one serial queue, in the order asked for, off the
    /// main thread: grouping or pinning a tab writes a file per space, and
    /// doing that on the main thread stalled the frame it happened in.
    /// The one place that has to wait for the disk is quitting (see settle).
    static func write(space: UUID = Space.firstID, _ shape: Shape) {
        let file = file(space)
        let put = {
            guard let data = try? JSONEncoder().encode(shape) else { return }
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: file, options: .atomic)
        }
        writes.async(execute: put)
    }

    /// Waits for every save asked for so far to reach disk: on quit, before
    /// there is no process left to finish them.
    static func settle() {
        writes.sync {}
    }
}
