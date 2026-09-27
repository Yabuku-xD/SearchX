import Foundation

/// A named section of ordinary tabs in one space's tab layout.
/// Its tabs remain ordinary tabs; their own group IDs describe membership.
struct TabGroup: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var collapsed: Bool
    /// An emoji chosen as its icon. Nil shows the first page's own icon.
    /// A session from when groups had colours decodes with none.
    var emoji: String? = nil
}
