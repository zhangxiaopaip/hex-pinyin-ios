import UIKit
import XCTest
@testable import HEX

/// 简体中文 typing through the keys: the pinyin letters stay in the field while the strip offers
/// what they spell, and space, a mark or a pick replaces them with the word.
@MainActor
final class PinyinKeyboardTests: XCTestCase {
    private var target: FixtureTextTarget!
    private var engine: FullKeyboardEngine!
    private var nextID = 1

    override func setUp() async throws {
        target = FixtureTextTarget()
        target.autocapitalizationType = UITextAutocapitalizationType.none
        engine = FullKeyboardEngine(target: target)
        engine.width = 393
        engine.language = .chinese
        engine.configureForField()
    }

    private func tap(_ kind: KeyKind) {
        guard let key = engine.layout.key(kind) else { return XCTFail("no \(kind)") }
        let point = CGPoint(x: key.frame.midX, y: key.frame.midY)
        engine.touchBegan(id: nextID, at: point)
        engine.touchEnded(id: nextID, at: point)
        nextID += 1
    }

    private func type(_ letters: String) {
        for letter in letters.map(String.init) { tap(.character(letter)) }
    }

    /// The letters are typed as they are, and the strip offers the words they spell.
    func testLettersTypeAndTheStripOffersWords() {
        type("nihao")
        XCTAssertEqual(target.text, "nihao")
        XCTAssertEqual(engine.chinese.buffer, "nihao")
        XCTAssertEqual(engine.suggestions.first?.replacement, "你好")
    }

    /// Space puts the strip's first word in place of the letters, and types no space after it,
    /// as Apple's Chinese keyboard does.
    func testSpacePutsTheFirstWordIn() {
        type("nihao")
        tap(.space)
        XCTAssertEqual(target.text, "你好")
        XCTAssertTrue(engine.chinese.buffer.isEmpty)
        XCTAssertTrue(engine.suggestions.isEmpty, "no run, nothing to spell")
    }

    /// A double space after Chinese text ends the sentence with the full-width stop, as
    /// Apple's Chinese keyboard does.
    func testADoubleSpaceAfterChineseTextTypesAFullStop() {
        type("nihao")
        tap(.space)
        tap(.space)
        tap(.space)
        XCTAssertEqual(target.text, "你好。 ")
    }

    /// A slot picked replaces the run with its own word.
    func testAPickedSlotReplacesTheRun() {
        // 万象拼音 gives 你好 alone for nihao, so a run with several readings ("shi") is
        // where a second slot exists to pick.
        type("shi")
        guard let second = engine.suggestions.dropFirst().first else { return XCTFail("no second slot") }
        engine.acceptSuggestion(second)
        XCTAssertEqual(target.text, second.replacement)
        XCTAssertTrue(engine.chinese.buffer.isEmpty)
    }

    /// Delete takes the run back one letter, the field following it.
    func testDeleteTakesTheRunBackALetter() {
        type("nihao")
        engine.deleteBackward()
        XCTAssertEqual(target.text, "niha")
        XCTAssertEqual(engine.chinese.buffer, "niha")
        engine.deleteBackward()
        engine.deleteBackward()
        engine.deleteBackward()
        engine.deleteBackward()
        XCTAssertEqual(target.text, "")
        XCTAssertTrue(engine.chinese.buffer.isEmpty)
    }

    /// A mark on the numbers page ends the run with its word, and goes in full-width after the
    /// Chinese text it follows.
    func testAMarkEndsTheRunFullWidth() {
        type("nihao")
        tap(.layerSwitch(.numbers))
        tap(.character(","))
        XCTAssertEqual(target.text, "你好，")
        XCTAssertTrue(engine.chinese.buffer.isEmpty)
    }

    /// A mark after Latin text is the mark it is: a decimal point stays one.
    func testAMarkAfterLatinStaysAsItIs() {
        type("abc")
        XCTAssertTrue(engine.suggestions.isEmpty, "no pinyin spells it")
        tap(.layerSwitch(.numbers))
        tap(.character("."))
        XCTAssertEqual(target.text, "abc.", "the letters stood as they were, and so did the mark")
    }

    /// Letters no pinyin spells are kept as they are: space leaves them, and types no space.
    func testALetterRunNoPinyinSpellsIsKept() {
        type("zzz")
        XCTAssertTrue(engine.suggestions.isEmpty)
        tap(.space)
        XCTAssertEqual(target.text, "zzz")
        XCTAssertTrue(engine.chinese.buffer.isEmpty)
    }

    /// Leaving the letters page takes the run's first word in, as a mark does.
    func testAPageSwitchTakesTheFirstWordIn() {
        type("nihao")
        tap(.layerSwitch(.numbers))
        XCTAssertEqual(target.text, "你好")
        XCTAssertTrue(engine.chinese.buffer.isEmpty)
        XCTAssertTrue(engine.suggestions.isEmpty)
    }

    /// 简体中文 types pinyin on the English letters, holds no accent, and has no word list to
    /// autocorrect into another language with.
    func testChineseTypesOnTheEnglishLetters() {
        XCTAssertEqual(KeyboardLanguage.chinese.letterRows, [["q","w","e","r","t","y","u","i","o","p"], ["a","s","d","f","g","h","j","k","l"], ["z","x","c","v","b","n","m"]])
        XCTAssertEqual(KeyboardLanguage.chinese.letterLayouts, [.qwerty])
        XCTAssertTrue(KeyboardLanguage.chinese.letterHolds.isEmpty)
        XCTAssertTrue(KeyboardLanguage.chinese.spellCheckCandidates.isEmpty)
        XCTAssertEqual(KeyboardLanguage.chinese.inputModeLanguage, "zh-Hans")
        XCTAssertEqual(KeyboardLanguage.chinese.displayName, "简体中文")
        XCTAssertEqual(KeyboardLanguage.matching("zh-Hans-CN"), .chinese)
    }
}
