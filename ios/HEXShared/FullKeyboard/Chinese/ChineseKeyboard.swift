import Foundation

/// Settings › Keyboard › Languages › 简体中文, and the pinyin run its keys feed
/// (`FullKeyboardEngine+Chinese`): the letters typed stay in the field ("nihao") and the
/// candidate bar offers the words they spell. Picking one, or a space or mark that ends the
/// run, replaces the letters with it; return commits the letters as typed instead.
///
/// The run asks 万象拼音's dictionary (Rime's word list) for its candidates, which come
/// likeliest first: whole words, several words read as one, half-typed syllables and
/// 简拼 initials, as Rime's engine offers them — and with a typo repaired, so a mistyped
/// syllable still finds its word.
nonisolated struct ChineseKeyboardState: Sendable {
    /// How many words a run keeps: the bar pages through them.
    static let candidates = 60

    /// The pinyin letters in the field now.
    private(set) var buffer = ""
    /// What they spell, the likeliest first: kept beside the buffer, so a strip refresh while
    /// no key changed costs nothing, and the run's words are read once.
    private(set) var words: [String] = []
    /// The syllables the leading word was read as, joined by "'" ("ni'hao"): what the bar shows
    /// above the words, and where a repaired spelling shows itself.
    private(set) var spelling = ""
    /// Whether the leading word was found under a spelling other than the one typed.
    private(set) var corrected = false
    /// Bumped whenever the run changes, so the bar turns back to its first page.
    private(set) var generation = 0

    /// Whether a run is composing: its letters are in the field, waiting for a word.
    var hasRun: Bool { !buffer.isEmpty }

    /// A pinyin letter typed.
    mutating func type(_ letter: String) {
        buffer += letter
        search()
    }

    /// The last letter taken back: delete takes the run back one letter at a time.
    mutating func removeLast() {
        guard !buffer.isEmpty else { return }
        buffer.removeLast()
        search()
    }

    /// The run ended: its letters, where they stayed in the field, are the host's text.
    mutating func reset() {
        buffer = ""
        words = []
        spelling = ""
        corrected = false
        generation += 1
    }

    /// What the run spells now, and how it was read to spell it.
    private mutating func search() {
        defer { generation += 1 }
        guard !buffer.isEmpty else {
            words = []
            spelling = ""
            corrected = false
            return
        }
        let found = PinyinDictionary.shared.candidates(for: buffer, limit: Self.candidates)
        words = found.map(\.text)
        // The bar shows the syllables apart ("ni'hao"), and the check for a repaired spelling
        // reads the same letters: apostrophes are display, not something the typist typed.
        spelling = found.first.map { PinyinDictionary.shared.apart($0.spelling) } ?? ""
        corrected = !spelling.isEmpty && spelling.replacingOccurrences(of: "'", with: "") != buffer
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
