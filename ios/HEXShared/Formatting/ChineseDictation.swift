import Foundation

/// Chinese dictation written back the way Chinese is written: 「，」 in place of 「,」, no gap
/// between two characters, a word said twice on the way to a sentence written once, and the
/// phrases a speaker thinks aloud with — 「那个，」「就是说，」「你知道吗，」 — left out.
///
/// The sounds come first, from `UnspacedFillers`: 「嗯」「呃」「啊」 are single characters and go
/// wherever they stand. The phrases here need a heading, because they are words as well:
/// 「那个红色的包」 keeps its 那个, and a 「那个，」 that opens a clause does not. Both are
/// Settings › Dictation › Chinese, on until turned off, and stored in the App Group so the
/// keyboard's own dictation follows them too.
nonisolated enum ChineseDictation {
    // MARK: Chinese

    /// The languages written in Chinese characters: Mandarin above all, and Cantonese and
    /// Wu, whose tics differ but whose marks do not.
    static func isChinese(_ language: String?) -> Bool {
        guard let code = language.flatMap({ Locale(identifier: $0).language.languageCode?.identifier }) else {
            return false
        }
        return ["zh", "cmn", "wuu", "yue"].contains(code)
    }

    /// Mandarin's own tics: Cantonese writes 「呢個」 and 「即係」, which these lists would miss
    /// and mangle, so only Mandarin is tidied of them.
    private static func speaksMandarin(_ language: String?) -> Bool {
        guard let code = language.flatMap({ Locale(identifier: $0).language.languageCode?.identifier }) else {
            return false
        }
        return ["zh", "cmn", "wuu"].contains(code)
    }

    // MARK: Tidy

    /// `text` as written Chinese: half-width marks made full-width, no space between two
    /// characters, a repeated word once, and the punctuation a removal leaves behind tidied.
    /// `text` itself when it isn't Chinese, or when Settings › Dictation › Tidy Chinese is off.
    /// `punctuation` is Settings › Dictation › Spoken punctuation: 「逗号」 and 「换行」 said by
    /// name become 「，」 and a line break.
    static func polish(
        _ text: String,
        language: String?,
        punctuation: Bool = false,
        settings: ChineseDictationSettings = ChineseDictationSettings()
    ) -> String {
        guard isChinese(language), !text.isEmpty, settings.isTidy else { return text }
        var out = punctuation ? writtenMarks(in: text) : text
        out = fullWidthMarks(in: out)
        out = TranscriptFormatter.closingUnspacedGaps(in: out)
        out = collapsingRepeats(in: out)
        return tidied(out)
    }

    /// Half-width 「, . ? ! : ;」 beside a character become 「，。？！：；」: a recogniser sometimes
    /// writes "牛奶,然后" where Chinese writes "牛奶，然后". A mark after a Latin word or a number
    /// stays half-width ("iPhone.", "3:30", "3.14"), and so does everything else it marks.
    private static func fullWidthMarks(in text: String) -> String {
        let marks: [Character: Character] = [",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；"]
        let chars = Array(text)
        var out = chars
        for index in chars.indices {
            guard let mark = marks[chars[index]], index > 0,
                  TranscriptFormatter.isUnspacedScript(chars[index - 1]) else { continue }
            out[index] = mark
        }
        return String(out)
    }

    /// A word said twice on the way to a sentence, written once: 「我我我觉得」 -> 「我觉得」,
    /// 「这个这个」 -> 「这个」. One character repeats from three (「我我我」), because two are
    /// often a word (「看看」「慢慢」「谢谢」); two or three characters repeat from two, but only
    /// when they hold no number: 「一个一个来」 and 「一天一天」 count, and stay.
    private static func collapsingRepeats(in text: String) -> String {
        let numerals: Set<Character> = [
            "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "两", "几", "半", "每", "第",
        ]
        // A word of two or three characters first, so 「谢谢谢谢」 is 「谢谢」 and not 「谢」.
        var out = replacing(#"([\u4E00-\u9FFF]{2,3})\1+"#, in: text) { groups in
            let word = groups[0]
            guard !word.isEmpty, !word.contains(where: numerals.contains) else { return nil }
            return word
        }
        out = replacing(#"([\u4E00-\u9FFF])(?:\1){2,}"#, in: out) { groups in
            groups[0].isEmpty ? nil : String(groups[0].prefix(1))
        }
        return out
    }

    /// What a removal leaves behind: 「，，」 -> 「，」, 「，。」 -> 「。」, no space beside a
    /// full-width mark or between two characters, and no comma left at the start or the end of
    /// the line (a sentence's 「。」 is added after this, by the style).
    private static let tidyRules: [(pattern: String, template: String)] = [
        (#"(?<=[\u4E00-\u9FFF])[ \t\x{3000}]+(?=[\u4E00-\u9FFF])"#, ""),
        (#"[，、]{2,}"#, "，"),
        (#"[，、](?=[。！？；：])"#, ""),
        (#"[，、](?=\n)"#, "。"),
        (#"。{2,}"#, "。"),
        (#"[；：]{2,}"#, "；"),
        (#"(?:(?<=\n)|^)[ \t\x{3000}]*[，、。；：]+[ \t\x{3000}]*"#, ""),
        (#"[ \t\x{3000}]+(?=[，。！？；：、」』）])"#, ""),
        (#"(?<=[「『（])[ \t\x{3000}]+"#, ""),
        (#"[，、]+$"#, ""),
        (#"[ \t\x{3000}]+$"#, ""),
    ]

    private static func tidied(_ text: String) -> String {
        var out = text
        for rule in tidyRules {
            out = replacing(rule.pattern, with: rule.template, in: out)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Verbal tics

    /// The phrases a speaker thinks aloud with, longest first, and what each leaves in place:
    /// 「然后就是，」 keeps its 然后, the rest go in full.
    private static let tics: [[String]] = [
        ["你明白我意思吧", ""], ["你懂我意思吧", ""],
        ["你知道吗", ""], ["你知道吧", ""], ["你明白吧", ""], ["你懂吧", ""],
        ["怎么说呢", ""], ["怎么讲呢", ""], ["就是说呢", ""], ["就是说", ""],
        ["那个什么", ""], ["那个啥", ""], ["那个", ""],
        ["然后就是", "然后"], ["然后吧", "然后"], ["然后呢", "然后"],
        ["反正吧", ""], ["反正呢", ""], ["其实吧", ""], ["其实呢", ""], ["说实话", ""],
    ]

    /// `text` without the phrases it thinks aloud with, or `text` itself when it isn't
    /// Mandarin or Settings › Dictation › Drop verbal tics is off.
    ///
    /// A tic goes only where a clause begins — at the start of the line, or after a mark —
    /// and with a comma after it. Mid-sentence 「那个」 is a word: 「我喜欢那个，红色的」 keeps it,
    /// and so does a 「那个」 with no comma of its own. The sounds 「嗯」「啊」 are
    /// `UnspacedFillers`', which runs before this, so 「嗯，那个，」 arrives here as 「那个，」.
    static func removingTics(
        _ text: String,
        language: String?,
        settings: ChineseDictationSettings = ChineseDictationSettings()
    ) -> String {
        guard settings.dropsTics, speaksMandarin(language), !text.isEmpty else { return text }
        var out = text
        // One removal leaves its heading for the next tic to stand on ("，那个，就是说，"), so
        // this runs until nothing changes; it ends, because every pass shortens the line.
        for _ in 0..<4 {
            let before = out
            for tic in tics {
                let phrase = NSRegularExpression.escapedPattern(for: tic[0])
                out = replacing("(^|[，。！？；：、…\\n])" + phrase + "[，、]", in: out) { groups in
                    groups[0] + tic[1]
                }
            }
            // 「，对吧？」 after a statement is a tag, not a question of its own: the tag and
            // its comma go, the sentence keeps the mark ("明天去吧，对吧？" -> "明天去吧？").
            out = replacing("([，、])(?:对吧|是吧)([，。！？]?)", in: out) { groups in groups[1] }
            if out == before { break }
        }
        return out
    }

    // MARK: Spoken marks

    /// 「逗号」 and its neighbours said by name, as the mark (Settings › Dictation › Spoken
    /// punctuation). Chinese has no spaces, so `SpokenPunctuation`'s word table never sees
    /// them; the mark replaces the word and the comma after it, and `tidied` closes the gap.
    private static let spokenMarks: [[String]] = [
        ["另起一行", "\n"], ["新的一行", "\n"], ["换行", "\n"], ["回车", "\n"],
        ["感叹号", "！"], ["叹号", "！"], ["问号", "？"], ["句号", "。"], ["逗号", "，"],
        ["分号", "；"], ["冒号", "："], ["顿号", "、"], ["省略号", "…"],
    ]

    private static func writtenMarks(in text: String) -> String {
        var out = text
        for mark in spokenMarks {
            let word = NSRegularExpression.escapedPattern(for: mark[0])
            out = replacing(word + "[，。]?[ \\t\\x{3000}]*", in: out) { _ in mark[1] }
        }
        return out
    }

    // MARK: Replacing

    /// `text` with each match of `pattern` replaced by what `replacement` returns for its
    /// capture groups; nil keeps the match as it stands.
    private static func replacing(
        _ pattern: String,
        in text: String,
        _ replacement: ([String]) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var out = ""
        var cursor = text.startIndex
        for match in matches {
            guard let whole = Range(match.range, in: text) else { continue }
            var groups: [String] = []
            for index in 1..<match.numberOfRanges {
                if let range = Range(match.range(at: index), in: text) {
                    groups.append(String(text[range]))
                } else {
                    groups.append("")
                }
            }
            guard let replaced = replacement(groups) else { continue }
            out += text[cursor..<whole.lowerBound]
            out += replaced
            cursor = whole.upperBound
        }
        return out + text[cursor...]
    }

    private static func replacing(_ pattern: String, with template: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

/// Settings › Dictation › Chinese: a Chinese dictation written as Chinese is (Tidy Chinese),
/// and the phrases it thinks aloud with left out (Drop verbal tics). Both on: a dictated
/// message reads better without them, and either can be turned off. In the App Group, so the
/// keyboard's own dictation follows the app's choice.
nonisolated struct ChineseDictationSettings {
    private enum Key {
        static let tidy = "dictation.chineseTidy"
        static let tics = "dictation.chineseTics"
    }

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = KeyboardBridge.storage) {
        self.defaults = defaults
    }

    /// 「，」 for 「,」, no gap between two characters, a repeated word once.
    var isTidy: Bool {
        get { defaults?.object(forKey: Key.tidy) as? Bool ?? true }
        nonmutating set { defaults?.set(newValue, forKey: Key.tidy) }
    }

    /// 「那个，」「就是说，」「你知道吗，」 and the like left out.
    var dropsTics: Bool {
        get { defaults?.object(forKey: Key.tics) as? Bool ?? true }
        nonmutating set { defaults?.set(newValue, forKey: Key.tics) }
    }
}
