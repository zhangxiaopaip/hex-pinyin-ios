import Foundation

/// 简拼 phrases the dictionary's own initials table leaves out ("fyx" -> 发一下): 万象拼音's
/// word list holds words, and a phrase said all the time in chat — 发一下, 发个截图, 那这样 —
/// may not be one of them, or its initials answer to a rarer word first (万象's own table
/// reads "fyx" as 放一些, for 发一些 outranks nothing the way a spoken 发一下 should).
///
/// As Rime's custom phrases, this is a list the engine reads beside the dictionary, and the
/// list is written here rather than built from a corpus: a phrase earns its place by being
/// said, not by being a word. Each entry spells its syllables out ("fa'yi'xia"), and every
/// way the typist may shorten it — all initials ("fyx"), or any syllable typed whole
/// ("fyxia") — is indexed once when the keyboard loads, so a lookup is one dictionary hit.
///
/// Kept to Foundation alone so `scripts/verify-pinyin-index.swift` compiles it with the
/// dictionary code and checks the table against the shipped file before a build.
nonisolated final class PinyinShortPhrases: @unchecked Sendable {
    static let shared = PinyinShortPhrases()

    /// One phrase: what goes in the field, its syllables, and a share of a corpus in the
    /// dictionary's own scale — a common word is ten thousands, a rare one hundreds. Every
    /// phrase here beats the stray words its initials otherwise spell (放一些 at 2,581), and
    /// sits under a real word the initials name (打游戏 at 17,050 keeps dyx).
    struct Entry {
        let text: String
        let spelling: String
        let weight: Double
    }

    /// What weights the table's kinds of phrase carry. A 一下 after a verb is said constantly;
    /// a 发个 something is the chat's daily bread; a set phrase or an idiom is rarer.
    private static let verbYixia = 9000.0
    private static let geSomething = 7000.0
    private static let saidPhrase = 6000.0
    private static let setPhrase = 4500.0

    /// The phrases, written by hand: the anchor that started them ("fyx" typed nothing of
    /// the sort), and the rest the same way a chat says them.
    private static let listed: [Entry] = [
        // …一下, and the verbs whose initials the dictionary gives to some 一some else.
        Entry(text: "发一下", spelling: "fa'yi'xia", weight: verbYixia),
        Entry(text: "来一下", spelling: "lai'yi'xia", weight: verbYixia),
        Entry(text: "玩一下", spelling: "wan'yi'xia", weight: verbYixia),
        Entry(text: "点一下", spelling: "dian'yi'xia", weight: verbYixia),
        Entry(text: "做一下", spelling: "zuo'yi'xia", weight: verbYixia),
        Entry(text: "坐一下", spelling: "zuo'yi'xia", weight: verbYixia),
        Entry(text: "等一下", spelling: "deng'yi'xia", weight: verbYixia),
        Entry(text: "用一下", spelling: "yong'yi'xia", weight: verbYixia),
        Entry(text: "换一下", spelling: "huan'yi'xia", weight: verbYixia),
        Entry(text: "帮一下", spelling: "bang'yi'xia", weight: verbYixia),
        Entry(text: "试一下", spelling: "shi'yi'xia", weight: verbYixia),
        Entry(text: "听一下", spelling: "ting'yi'xia", weight: verbYixia),
        Entry(text: "拍一下", spelling: "pai'yi'xia", weight: verbYixia),
        Entry(text: "聊一下", spelling: "liao'yi'xia", weight: verbYixia),
        Entry(text: "搜一下", spelling: "sou'yi'xia", weight: verbYixia),
        Entry(text: "改一下", spelling: "gai'yi'xia", weight: verbYixia),
        Entry(text: "写一下", spelling: "xie'yi'xia", weight: verbYixia),
        Entry(text: "想一下", spelling: "xiang'yi'xia", weight: verbYixia),
        Entry(text: "拿一下", spelling: "na'yi'xia", weight: verbYixia),
        // 发个…, 回个…, the messages a chat sends by their initials alone.
        Entry(text: "发个消息", spelling: "fa'ge'xiao'xi", weight: geSomething),
        Entry(text: "发个红包", spelling: "fa'ge'hong'bao", weight: geSomething),
        Entry(text: "发个定位", spelling: "fa'ge'ding'wei", weight: geSomething),
        Entry(text: "发个截图", spelling: "fa'ge'jie'tu", weight: geSomething),
        Entry(text: "发个照片", spelling: "fa'ge'zhao'pian", weight: geSomething),
        Entry(text: "发个链接", spelling: "fa'ge'lian'jie", weight: geSomething),
        Entry(text: "发个文件", spelling: "fa'ge'wen'jian", weight: geSomething),
        Entry(text: "发个地址", spelling: "fa'ge'di'zhi", weight: geSomething),
        Entry(text: "回个电话", spelling: "hui'ge'dian'hua", weight: geSomething),
        Entry(text: "回个消息", spelling: "hui'ge'xiao'xi", weight: geSomething),
        Entry(text: "回条消息", spelling: "hui'tiao'xiao'xi", weight: geSomething),
        Entry(text: "开个会议", spelling: "kai'ge'hui'yi", weight: geSomething),
        Entry(text: "开个视频", spelling: "kai'ge'shi'pin", weight: geSomething),
        // Phrases said as they are, whose initials the dictionary hands to stray words.
        Entry(text: "别着急", spelling: "bie'zhao'ji", weight: saidPhrase),
        Entry(text: "那这样", spelling: "na'zhe'yang", weight: saidPhrase),
        Entry(text: "为什么呀", spelling: "wei'shen'me'ya", weight: saidPhrase),
        Entry(text: "有意思", spelling: "you'yi'si", weight: saidPhrase),
        Entry(text: "团建活动", spelling: "tuan'jian'huo'dong", weight: saidPhrase),
        Entry(text: "你的电话", spelling: "ni'de'dian'hua", weight: setPhrase),
        Entry(text: "我的电话", spelling: "wo'de'dian'hua", weight: setPhrase),
        Entry(text: "一言为定", spelling: "yi'yan'wei'ding", weight: setPhrase),
    ]

    private let entries: [Entry]
    /// Every spelling the syllables may be typed as — each syllable as its initial or whole —
    /// against the entries that answer to it.
    private let forms: [String: [Int]]

    private init() {
        entries = Self.listed
        var built: [String: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            for form in Self.forms(of: entry.spelling.split(separator: "'").map(String.init)) {
                built[form, default: []].append(index)
            }
        }
        forms = built
    }

    /// Every spelling `syllables` may be typed as. A syllable of one letter has one spelling,
    /// not two, and the same form twice takes one slot.
    private static func forms(of syllables: [String]) -> [String] {
        var out: Set<String> = [""]
        for syllable in syllables {
            var next: Set<String> = []
            for partial in out {
                next.insert(partial + String(syllable.first!))
                next.insert(partial + syllable)
            }
            out = next
        }
        return out.sorted()
    }

    /// The phrases the typed letters answer to, the commoner first. Empty letters answer
    /// nothing, and so does anything past a phrase's worth of initials.
    func words(for input: String) -> [(text: String, weight: Double)] {
        guard input.count >= 2, input.count <= 12, let hits = forms[input] else { return [] }
        return hits
            .map { (text: entries[$0].text, weight: entries[$0].weight) }
            .sorted(by: { $0.weight > $1.weight })
    }

    /// The table as it stands, for the check before a build: every spelling a real pinyin's
    /// worth of syllables, every entry reachable through its own initials.
    func allEntries() -> [(text: String, spelling: String)] {
        entries.map { (text: $0.text, spelling: $0.spelling) }
    }
}
