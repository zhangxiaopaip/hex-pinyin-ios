import Foundation

/// Checks the shipped `Wanxiang.pinyin` against the code that reads it, before a build spends
/// twenty minutes on an archive. Run by `scripts/build-ipa.sh`:
///
///     swiftc -parse-as-library HEXShared/FullKeyboard/Chinese/PinyinIndex.swift \
///         HEXShared/FullKeyboard/Chinese/PinyinCorrection.swift \
///         HEXShared/FullKeyboard/Chinese/PinyinShortPhrases.swift \
///         HEXShared/FullKeyboard/Chinese/PinyinDictionary.swift \
///         scripts/verify-pinyin-stubs.swift scripts/verify-pinyin-index.swift \
///         -o /tmp/verify-pinyin && /tmp/verify-pinyin
///
/// The index is read by offset, so a wrong field is silent: the keyboard types bare letters
/// with no candidate and nothing in the build complains. This asserts the lookups instead —
/// the raw tables, and then the words a pinyin run spells. A run with a typo in it must find
/// its word too, or the correction shipped with the keyboard is worth nothing.
@main
struct VerifyPinyinIndex {
    static func main() {
        // `scripts/build-ipa.sh` runs this from `ios/`; a path argument overrides it.
        let file: URL = if CommandLine.arguments.count > 1 {
            URL(fileURLWithPath: CommandLine.arguments[1])
        } else {
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("HEXShared/FullKeyboard/Chinese/Wanxiang.pinyin")
        }
        guard let index = PinyinIndex(fileURL: file) else {
            fail("cannot map \(file.path)")
        }
        guard index.isLoaded, index.totalWeight > 0 else {
            fail("the index mapped nothing")
        }

        var failures = 0
        func expect(_ key: String, _ table: PinyinIndex.Table, _ wanted: String) {
            let texts = index.entries(for: key, in: table).map(\.text)
            if texts.prefix(3).contains(wanted) || texts.contains(wanted) {
                print("  ok   \(VerifyPinyinIndex.tableName(table)) \(key) -> \(texts.prefix(4).joined(separator: " "))")
            } else {
                failures += 1
                print("  FAIL \(VerifyPinyinIndex.tableName(table)) \(key): wanted \(wanted), got \(texts.prefix(4))")
            }
        }

        expect("ni", .full, "你")
        expect("nihao", .full, "你好")
        expect("zhang", .full, "张")
        expect("shijie", .full, "世界")
        expect("nih", .prefix, "你好")
        expect("nh", .abbrev, "你好")

        // Every letter a pinyin syllable starts with has a bucket; i, u and v start none
        // (they are spelled yi, wu and yu), so their buckets are empty by design.
        var empty: [Character] = []
        for letter in "abcdefghijklmnopqrstuvwxyz"
        where !"iuv".contains(letter) && index.recordCount(for: letter) == 0 {
            empty.append(letter)
        }
        if !empty.isEmpty {
            failures += 1
            print("  FAIL buckets with no words: \(String(empty))")
        }

        // The dictionary as the keyboard reads it — the beam, the half-typed tail, the near
        // keys — over the shipped file: what the bar will show, and how it read the run.
        guard let dictionary = PinyinDictionary(fileURL: file) else {
            fail("cannot read \(file.path) as a dictionary")
        }
        func expectWord(_ typed: String, _ wanted: String, spelling: String? = nil) {
            let found = dictionary.candidates(for: typed, limit: 8)
            let texts = found.map(\.text)
            guard texts.prefix(3).contains(wanted) else {
                failures += 1
                print("  FAIL \(typed): wanted \(wanted), got \(texts.prefix(4))")
                return
            }
            if let spelling, found.first?.spelling != spelling {
                failures += 1
                print("  FAIL \(typed): read as \(found.first?.spelling ?? "-"), wanted \(spelling)")
                return
            }
            print("  ok   \(typed) -> \(texts.prefix(4).joined(separator: " "))  [\(found.first?.spelling ?? "")]")
        }

        expectWord("nihao", "你好", spelling: "nihao")
        expectWord("zhang", "张")
        expectWord("shijie", "世界", spelling: "shijie")
        expectWord("zhongguo", "中国", spelling: "zhongguo")
        // Two letters the wrong way round: no pinyin spells "zhagn", and the near key does.
        expectWord("zhagn", "张", spelling: "zhang")
        // A key held too long: the run is read again with the second letter taken out.
        expectWord("nihhaoo", "你好", spelling: "nihao")

        // 简拼 phrases (`PinyinShortPhrases`): initials the dictionary spells with stray words,
        // and the phrase a chat says instead — "fyx" was 放一些 and nothing of 发一下 before the
        // table, and a syllable typed whole answers too ("fyxia"). The spelling shown is the
        // initials as typed, no split a syllable would give them.
        expectWord("fyx", "发一下", spelling: "fyx")
        expectWord("fyxia", "发一下", spelling: "fyxia")
        expectWord("dyx", "点一下")
        expectWord("hgxx", "回个消息")

        // The phrase table against the shipped file: every syllable is a pinyin the
        // dictionary spells, every entry reachable through its own initials, and no phrase
        // listed twice — a typo in the hand-written list would surface here, not on a phone.
        var listed: Set<String> = []
        for (text, spelling) in PinyinShortPhrases.shared.allEntries() {
            let syllables = spelling.split(separator: "'").map(String.init)
            if syllables.isEmpty || syllables.contains(where: { dictionary.words(for: $0).isEmpty }) {
                failures += 1
                print("  FAIL phrase \(text): \(spelling) is not a spelling of real syllables")
            }
            let initials = syllables.map { String($0.first!) }.joined()
            let found = PinyinShortPhrases.shared.words(for: initials).map { $0.text }
            if !found.contains(text) {
                failures += 1
                print("  FAIL phrase \(text): initials \(initials) do not answer it, got \(found.prefix(4))")
            }
            if !listed.insert("\(text)|\(spelling)").inserted {
                failures += 1
                print("  FAIL phrase \(text) (\(spelling)) listed twice")
            }
        }
        if failures == 0 {
            print("  ok   phrases: \(PinyinShortPhrases.shared.allEntries().count) entries, all syllables real, all initials answer")
        }

        // The line above the words, syllables apart as 豆包 shows them.
        for (run, apart) in [("nihao", "ni'hao"), ("zhongguo", "zhong'guo"), ("jintiantianqi", "jin'tian'tian'qi")] {
            let line = dictionary.apart(run)
            if line == apart {
                print("  ok   apart \(run) -> \(line)")
            } else {
                failures += 1
                print("  FAIL apart \(run) -> \(line), wanted \(apart)")
            }
        }

        guard failures == 0 else { fail("\(failures) check(s) failed") }
        print("Wanxiang.pinyin: \(index.totalWeight) total weight, all lookups answered")
    }

    private static func tableName(_ table: PinyinIndex.Table) -> String {
        switch table {
        case .full: "full"
        case .abbrev: "abbrev"
        case .prefix: "prefix"
        }
    }

    private static func fail(_ message: String) -> Never {
        print("verify-pinyin-index: \(message)")
        exit(1)
    }
}
