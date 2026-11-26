import Foundation

/// Takes the hesitation sounds out of a transcript written without spaces — Chinese, above
/// all. Every other cleanup path splits on spaces (`CleanupTagger.words`): a Chinese sentence
/// has none, so the whole line is one "word", and the tagger and the comma-based rules find
/// nothing to remove while 「嗯」「啊」 stay in the text. This works on the characters.
///
/// Only sounds are removed, never words: 「嗯」「唔」「呃」 spell no common Chinese word and go
/// wherever they stand, while 「啊」「哦」「额」「唉」「哎」 are also words or sentence mood
/// (「额度」「额外」「好啊」) and go only when punctuation sets them off.
nonisolated enum UnspacedFillers {
    /// Sounds that never spell a word on their own.
    private static let pure = "[嗯唔呃]+"

    /// Sounds that are a filler only when set off: at the ends of the line, or between
    /// punctuation. Half-width marks are in too, which a recogniser sometimes writes.
    private static let hedged = #"(^|[，。！？；：、…,\.!\?;:\s])[啊哦额唉哎]+(?=[，。！？；：、…,\.!\?;:\s]|$)"#

    /// Punctuation a removed sound can leave behind: 「嗯，我觉得」 -> 「，我觉得」, and
    /// 「好，嗯，走」 -> 「好，，走」.
    private static let tidy: [(String, String)] = [
        (#"[，、]{2,}"#, "，"),
        (#"[，、](?=[。！？])"#, ""),
        (#"^\s*[，、。；：]+\s*"#, ""),
        (#"[ \t]{2,}"#, " "),
    ]

    /// `text` with its hesitation sounds gone, or nil when the language isn't written without
    /// spaces (the caller has other rules for those).
    static func clean(_ text: String, language: String?) -> String? {
        guard isUnspaced(language) else { return nil }
        var out = replacing(pure, in: text, with: "")
        out = replacing(hedged, in: out, with: "$1")
        for (pattern, template) in tidy {
            out = replacing(pattern, in: out, with: template)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a language writes its sentences without spaces between words. Korean spaces
    /// them, so it is not one of these.
    static func isUnspaced(_ language: String?) -> Bool {
        guard let code = language.flatMap({ Locale(identifier: $0).language.languageCode?.identifier }) else {
            return false
        }
        return ["zh", "ja", "yue"].contains(code)
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
