import Foundation

/// The picker's top-level emoji sections, ordered the way the system emoji
/// keyboard presents them. emojibase splits "Smileys & Emotion" (group 0) from
/// "People & Body" (group 1); we merge them into one section like Apple does,
/// so the very first page is the familiar wall of faces.
public enum EmojiCategory: Int, CaseIterable, Sendable {
    case smileysAndPeople
    case animalsAndNature
    case foodAndDrink
    case activities
    case travelAndPlaces
    case objects
    case symbols
    case flags

    /// Section header shown above the grid.
    public var title: String {
        switch self {
        case .smileysAndPeople: "Smileys & People"
        case .animalsAndNature: "Animals & Nature"
        case .foodAndDrink: "Food & Drink"
        case .activities: "Activities"
        case .travelAndPlaces: "Travel & Places"
        case .objects: "Objects"
        case .symbols: "Symbols"
        case .flags: "Flags"
        }
    }

    /// Maps an emojibase `group` number to a display category. Group 2
    /// (Component) is excluded upstream in the data generator, so it never
    /// reaches here; any unexpected value falls back to Symbols rather than
    /// dropping the glyph.
    public static func from(group: Int) -> EmojiCategory {
        switch group {
        case 0,
             1: .smileysAndPeople
        case 3: .animalsAndNature
        case 4: .foodAndDrink
        case 5: .travelAndPlaces
        case 6: .activities
        case 7: .objects
        case 8: .symbols
        case 9: .flags
        default: .symbols
        }
    }
}
