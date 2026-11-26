import Foundation

/// Checks the shipped `Wanxiang.pinyin` against the code that reads it, before a build spends
/// twenty minutes on an archive. Run by `scripts/build-ipa.sh`:
///
///     swiftc -parse-as-library HEXShared/FullKeyboard/Chinese/PinyinIndex.swift \
///         scripts/verify-pinyin-index.swift -o /tmp/verify-pinyin && /tmp/verify-pinyin
///
/// The index is read by offset, so a wrong field is silent: the keyboard types bare letters
/// with no candidate and nothing in the build complains. This asserts the lookups instead.
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

        var empty: [Character] = []
        for letter in "abcdefghijklmnopqrstuvwxyz" where index.entries(for: String(letter)).isEmpty {
            empty.append(letter)
        }
        if !empty.isEmpty {
            failures += 1
            print("  FAIL buckets with no words: \(String(empty))")
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
