import Foundation

/// Checks the Chinese rules before a build spends twenty minutes on an archive. Run by
/// `scripts/build-ipa.sh`:
///
///     swiftc -parse-as-library HEXShared/Formatting/ChineseDictation.swift \
///         HEXShared/Formatting/TranscriptFormatter.swift \
///         HEXShared/Formatting/SpokenLists.swift \
///         HEXShared/Formatting/SpokenPunctuation.swift \
///         HEXShared/Formatting/UnspacedFillers.swift \
///         scripts/verify-chinese-stubs.swift scripts/verify-chinese.swift \
///         -o /tmp/verify-chinese && /tmp/verify-chinese
///
/// Chinese has no spaces, so a rule that reads words finds nothing to do and the line comes out
/// as heard: 「嗯，那个，」 still has its filler, 「，，」 its doubled comma, and nothing in the
/// build complains. Every case below is a line a Chinese dictation really writes, with what it
/// is supposed to become.
@main
struct VerifyChinese {
    static func main() {
        var failures = 0

        func expect(_ got: String, _ wanted: String, _ what: String) {
            if got == wanted {
                print("  ok   \(what) -> \(got)")
            } else {
                failures += 1
                print("  FAIL \(what)\n         wanted \(wanted)\n         got    \(got)")
            }
        }

        print("marks and spaces")
        expect(
            TranscriptFormatter.format("牛奶, 然后我们走", style: .polished, language: "zh-CN"),
            "牛奶，然后我们走。",
            "a half-width comma beside a character"
        )
        expect(
            TranscriptFormatter.format("我用iPhone。", style: .polished, language: "zh-CN"),
            "我用iPhone。",
            "a full stop after a Latin word stays"
        )

        print("words said twice")
        expect(
            TranscriptFormatter.format("我我我觉得不对", style: .polished, language: "zh-CN"),
            "我觉得不对。",
            "我我我"
        )
        expect(
            TranscriptFormatter.format("这个这个，我们明天再说", style: .polished, language: "zh-CN"),
            "这个，我们明天再说。",
            "这个这个"
        )
        expect(
            TranscriptFormatter.format("谢谢谢谢", style: .polished, language: "zh-CN"),
            "谢谢。",
            "谢谢谢谢 keeps a word"
        )
        expect(
            TranscriptFormatter.format("一个一个来", style: .polished, language: "zh-CN"),
            "一个一个来。",
            "一个一个 counts"
        )
        expect(
            TranscriptFormatter.format("慢慢来吧", style: .polished, language: "zh-CN"),
            "慢慢来吧。",
            "慢慢 is a word"
        )

        print("a question")
        expect(
            TranscriptFormatter.format("你看那个红色的，好看吗", style: .polished, language: "zh-CN"),
            "你看那个红色的，好看吗？",
            "吗 takes ？"
        )

        print("verbal tics")
        expect(
            ChineseDictation.removingTics("那个，我觉得可以", language: "zh-CN"),
            "我觉得可以",
            "那个， at the start"
        )
        expect(
            ChineseDictation.removingTics("他说，就是说，这个不行", language: "zh-CN"),
            "他说，这个不行",
            "就是说， between commas"
        )
        expect(
            ChineseDictation.removingTics("然后就是，我们要注意安全", language: "zh-CN"),
            "然后我们要注意安全",
            "然后就是， keeps 然后"
        )
        expect(
            ChineseDictation.removingTics("你知道吗，他昨天没来", language: "zh-CN"),
            "他昨天没来",
            "你知道吗，"
        )
        expect(
            ChineseDictation.removingTics("我们明天去吧，对吧？", language: "zh-CN"),
            "我们明天去吧？",
            "a tag keeps the question"
        )
        expect(
            ChineseDictation.removingTics("我喜欢那个，红色的包", language: "zh-CN"),
            "我喜欢那个，红色的包",
            "mid-sentence 那个 is a word"
        )
        expect(
            ChineseDictation.removingTics("那个，我觉得", language: "yue"),
            "那个，我觉得",
            "Cantonese keeps its own"
        )

        print("spoken marks")
        expect(
            TranscriptFormatter.format("第一点，逗号，第二点", style: .polished, language: "zh-CN", punctuation: true),
            "第一点，第二点。",
            "逗号 said by name"
        )
        expect(
            TranscriptFormatter.format("我说完了，换行，下一段", style: .polished, language: "zh-CN", punctuation: true),
            "我说完了。\n下一段。",
            "换行 said by name"
        )

        print("another language")
        expect(
            TranscriptFormatter.format("I think so, that is fine", style: .polished, language: "en-US"),
            "I think so, that is fine.",
            "English is untouched"
        )

        guard failures == 0 else {
            print("\(failures) check(s) failed")
            exit(1)
        }
        print("Chinese dictation: all checks passed")
    }
}
