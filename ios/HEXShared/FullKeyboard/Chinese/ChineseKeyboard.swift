import Foundation

/// Settings › Keyboard › Languages › 简体中文, and the pinyin run its keys feed
/// (`FullKeyboardEngine+Chinese`): the letters typed stay in the field ("nihao") and the strip
/// offers the words they spell. Picking one, or a space, return or mark that ends the run,
/// replaces the letters with it.
nonisolated struct ChineseKeyboardState: Sendable {
    /// The pinyin letters in the field now.
    private(set) var buffer = ""
    /// What they spell, the likeliest first: kept beside the buffer, so a strip refresh while
    /// no key changed costs nothing, and the run's words are read once.
    private(set) var words: [String] = []

    /// Whether a run is composing: its letters are in the field, waiting for a word.
    var hasRun: Bool { !buffer.isEmpty }

    /// A pinyin letter typed.
    mutating func type(_ letter: String) {
        buffer += letter
        words = PinyinDictionary.shared.candidates(for: buffer)
    }

    /// The last letter taken back: delete takes the run back one letter at a time.
    mutating func removeLast() {
        guard !buffer.isEmpty else { return }
        buffer.removeLast()
        words = buffer.isEmpty ? [] : PinyinDictionary.shared.candidates(for: buffer)
    }

    /// The run ended: its letters, where they stayed in the field, are the host's text.
    mutating func reset() {
        buffer = ""
        words = []
    }
}

/// What a pinyin key may be: one of the 26 letters, which is all pinyin is spelled with.
nonisolated enum ChinesePinyin {
    static func isLetter(_ text: String) -> Bool {
        guard text.count == 1, let character = text.first else { return false }
        return character.isASCII && character.isLetter
    }

    /// A mark typed right after Chinese text, full-width as Apple's Chinese keyboard types it
    /// ("你好，"), and nil anywhere else, where it stays the character it is ("19.9", "a@b.com").
    static func fullWidth(_ mark: String, after previous: Character?) -> String? {
        guard let previous, isChinese(previous) else { return nil }
        switch mark {
        case ",": return "，"
        case ".": return "。"
        case "?": return "？"
        case "!": return "！"
        case ":": return "："
        case ";": return "；"
        default: return nil
        }
    }

    /// Whether `character` is a Chinese character (or a mark of its punctuation).
    static func isChinese(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
            || (0xFF00...0xFFEF).contains(scalar.value) || (0x3000...0x303F).contains(scalar.value)
    }
}
