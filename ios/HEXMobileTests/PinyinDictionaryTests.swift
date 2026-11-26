import XCTest
@testable import HEX

/// The Chinese keyboard's dictionary: what an everyday pinyin run spells, and how the file's
/// own lines are read.
final class PinyinDictionaryTests: XCTestCase {
    private let dictionary = PinyinDictionary.shared

    /// A word's pinyin run together finds the word first, not the characters it is made of.
    func testEverydayWordsComeFirst() {
        XCTAssertEqual(dictionary.candidates(for: "nihao").first, "你好")
        XCTAssertEqual(dictionary.candidates(for: "xiexie").first, "谢谢")
        XCTAssertEqual(dictionary.candidates(for: "zhongguo").first, "中国")
        XCTAssertEqual(dictionary.candidates(for: "women").first, "我们")
        XCTAssertEqual(dictionary.candidates(for: "meiyou").first, "没有")
        XCTAssertEqual(dictionary.candidates(for: "zhidao").first, "知道")
    }

    /// A character typed on its own, where one pinyin spells many: the commonest first.
    func testOneSyllableOffersItsCommonestCharacters() {
        XCTAssertEqual(dictionary.candidates(for: "shi").first, "是")
        XCTAssertEqual(dictionary.candidates(for: "wo").first, "我")
    }

    /// A polyphonic character reads as the word around it reads: yínháng, not yínxíng.
    func testAPolyphonicCharacterReadsRightInItsWord() {
        XCTAssertEqual(dictionary.candidates(for: "yinhang").first, "银行")
        XCTAssertEqual(dictionary.candidates(for: "yinyue").first, "音乐")
    }

    /// ü is typed v, as on any pinyin keyboard.
    func testUWithADiaeresisIsTypedV() {
        XCTAssertEqual(dictionary.candidates(for: "nv").first, "女")
        XCTAssertEqual(dictionary.candidates(for: "lvse").first, "绿色")
        XCTAssertTrue(dictionary.candidates(for: "lv", limit: 4).contains("绿"))
    }

    /// Half a syllable at the run's end still finds its word, the likeliest first.
    func testHalfATypedSyllableFindsItsWord() {
        XCTAssertEqual(dictionary.candidates(for: "nih").first, "你好")
    }

    /// A run of several words is read as the words it is ("今天" and "天气"), not letter by letter.
    func testALongRunIsReadAsWords() {
        XCTAssertEqual(dictionary.candidates(for: "jintiantianqi").first, "今天天气")
    }

    /// The strip has three slots: no more than three words, however many the run spells.
    func testNoMoreThanThreeWords() {
        XCTAssertLessThanOrEqual(dictionary.candidates(for: "shi").count, 3)
        XCTAssertEqual(dictionary.candidates(for: "shi", limit: 1).count, 1)
    }

    /// Letters no pinyin spells spell nothing: the keys keep them as they are.
    func testALetterRunNoPinyinSpellsOffersNothing() {
        XCTAssertTrue(dictionary.candidates(for: "zzz").isEmpty)
    }

    /// The file's lines: the header's total, then pinyin, word and frequency, the commonest
    /// of a pinyin first.
    func testParseReadsTheFilesLines() {
        let parsed = PinyinDictionary.parse(
            """
            # Hex's Chinese keyboard: pinyin (no tones, no spaces), the word, its frequency.
            # total: 1000
            a\t啊\t500
            a\t阿\t40
            ni\t你\t300
            """
        )
        XCTAssertEqual(parsed.candidates(for: "a"), ["啊", "阿"])
        XCTAssertEqual(parsed.candidates(for: "ni"), ["你"])
        XCTAssertTrue(parsed.candidates(for: "zzz").isEmpty)
    }
}
