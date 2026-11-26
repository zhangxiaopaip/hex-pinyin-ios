import XCTest
@testable import HEX

/// The Chinese keyboard's dictionary: what an everyday pinyin run spells, from the
/// 万象拼音 index (`Wanxiang.pinyin`) the keyboard ships.
final class PinyinDictionaryTests: XCTestCase {
    private let dictionary = PinyinDictionary.shared

    /// A word's pinyin run together finds the word first, not the characters it is made of.
    func testEverydayWordsComeFirst() {
        XCTAssertEqual(dictionary.candidates(for: "nihao").first?.text, "你好")
        XCTAssertEqual(dictionary.candidates(for: "xiexie").first?.text, "谢谢")
        XCTAssertEqual(dictionary.candidates(for: "zhongguo").first?.text, "中国")
        XCTAssertEqual(dictionary.candidates(for: "women").first?.text, "我们")
        XCTAssertEqual(dictionary.candidates(for: "meiyou").first?.text, "没有")
        XCTAssertEqual(dictionary.candidates(for: "zhidao").first?.text, "知道")
    }

    /// A character typed on its own, where one pinyin spells many: the commonest first.
    func testOneSyllableOffersItsCommonestCharacters() {
        XCTAssertEqual(dictionary.candidates(for: "shi").first?.text, "是")
        XCTAssertEqual(dictionary.candidates(for: "wo").first?.text, "我")
    }

    /// A polyphonic character reads as the word around it reads: yínháng, not yínxíng.
    func testAPolyphonicCharacterReadsRightInItsWord() {
        XCTAssertEqual(dictionary.candidates(for: "yinhang").first?.text, "银行")
        XCTAssertEqual(dictionary.candidates(for: "yinyue").first?.text, "音乐")
    }

    /// ü is typed v, as on any pinyin keyboard.
    func testUWithADiaeresisIsTypedV() {
        XCTAssertEqual(dictionary.candidates(for: "nv").first?.text, "女")
        XCTAssertEqual(dictionary.candidates(for: "lvse").first?.text, "绿色")
    }

    /// Half a syllable at the run's end still finds a word instead of nothing.
    func testHalfATypedSyllableStillOffersWords() {
        XCTAssertFalse(dictionary.candidates(for: "nih").isEmpty)
        XCTAssertFalse(dictionary.candidates(for: "zhongg").isEmpty)
    }

    /// A run of several words is read as the words it is ("今天" and "天气").
    func testALongRunIsReadAsWords() {
        XCTAssertEqual(dictionary.candidates(for: "jintiantianqi").first?.text, "今天天气")
    }

    /// 简拼: initials alone find the word, as Rime offers them.
    func testInitialsFindTheWord() {
        XCTAssertTrue(dictionary.candidates(for: "nh", limit: 9).map(\.text).contains("你好"))
        XCTAssertTrue(dictionary.candidates(for: "wm", limit: 9).map(\.text).contains("我们"))
    }

    /// The caller's limit is honoured: the bar pages through as many as it asks for.
    func testTheLimitIsHonoured() {
        XCTAssertLessThanOrEqual(dictionary.candidates(for: "shi").count, 3)
        XCTAssertEqual(dictionary.candidates(for: "shi", limit: 1).count, 1)
        XCTAssertLessThanOrEqual(dictionary.candidates(for: "shi", limit: 9).count, 9)
    }

    /// Letters no pinyin spells spell nothing: the keys keep them as they are.
    func testALetterRunNoPinyinSpellsOffersNothing() {
        XCTAssertTrue(dictionary.candidates(for: "zzz").isEmpty)
    }

    /// The index the keyboard ships is not empty: a dictionary that failed to load would
    /// type pinyin with nothing to pick, which is what this build set out to fix.
    func testTheShippedDictionaryLoads() {
        XCTAssertGreaterThanOrEqual(dictionary.candidates(for: "shi", limit: 9).count, 5)
        XCTAssertGreaterThanOrEqual(dictionary.candidates(for: "zhongguo", limit: 9).count, 1)
    }

    /// A pair of letters the wrong way round still finds the word, and says how it read it.
    func testATypoIsReadAsTheWordItMeant() {
        let found = dictionary.candidates(for: "zhagn", limit: 9)
        XCTAssertTrue(found.prefix(3).map(\.text).contains("张"), "got \(found.map(\.text).prefix(4))")
        XCTAssertEqual(found.first { $0.text == "张" }?.spelling, "zhang", "read as it was meant, not as typed")
    }

    /// A key held too long: the doubling is taken out, and 你好 beats what the letters spell.
    func testADoubledLetterIsReadOnce() {
        let found = dictionary.candidates(for: "nihhaoo", limit: 9)
        XCTAssertTrue(found.prefix(2).map(\.text).contains("你好"), "got \(found.map(\.text).prefix(4))")
        XCTAssertEqual(found.first?.spelling, "nihao", "read as nihao, with the second o taken out")
    }

    /// A spelling the dictionary answers is never corrected into a word it does not spell.
    func testACorrectSpellingIsLeftAlone() {
        let found = dictionary.candidates(for: "zang", limit: 9).map(\.text)
        XCTAssertFalse(found.contains("张"), "zang is not zhang: a spelled run is read as it stands")
    }
}
