import Foundation

/// A named section of ordinary tabs in one space's tab layout.
/// Its tabs remain ordinary tabs; their own group IDs describe membership.
struct TabGroup: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var collapsed: Bool
    /// Its colour, a dot beside its name. Nil in a session written before
    /// groups had colours.
    var tint: Tint? = nil
}
