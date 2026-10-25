import Foundation

struct PhysicalKey: Codable, Hashable {
    let keyCode: UInt16

    var displayName: String {
        switch keyCode {
        case 36:
            "Return"
        case 48:
            "Tab"
        case 49:
            "Space"
        case 51:
            "Delete"
        case 53:
            "Escape"
        case 54:
            "Right Command"
        case 55:
            "Left Command"
        case 56:
            "Left Shift"
        case 57:
            "Caps Lock"
        case 58:
            "Left Option"
        case 59:
            "Left Control"
        case 60:
            "Right Shift"
        case 61:
            "Right Option"
        case 62:
            "Right Control"
        case 63:
            "Fn / Globe"
        default:
            Self.letterKeyName(for: keyCode) ?? "Key Code \(keyCode)"
        }
    }

    var sortOrder: Int {
        switch keyCode {
        case 54, 55:
            0
        case 58, 61:
            1
        case 59, 62:
            2
        case 56, 60:
            3
        case 63:
            4
        default:
            100
        }
    }

    var shortcutRecorderDisplayName: String {
        switch keyCode {
        case 54:
            "⌘ʳ"
        case 55:
            "⌘ˡ"
        case 56:
            "⇧ˡ"
        case 58:
            "⌥ˡ"
        case 59:
            "⌃ˡ"
        case 60:
            "⇧ʳ"
        case 61:
            "⌥ʳ"
        case 62:
            "⌃ʳ"
        default:
            displayName
        }
    }

    private static func letterKeyName(for keyCode: UInt16) -> String? {
        let letterKeyCodes: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M"
        ]
        return letterKeyCodes[keyCode]
    }
}
