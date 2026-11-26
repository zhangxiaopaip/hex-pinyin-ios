import UIKit

/// Settings › Keyboard › Languages › 简体中文 (pinyin): the letter keys type pinyin and the field
/// shows it as typed, while the strip offers the words it spells (`PinyinDictionary`). Picking
/// one — or a space, return or mark that ends the run — replaces the letters with the word, by
/// deleting them and inserting it, as Hangul's syllables are replaced as they compose
/// (`FullKeyboardEngine+Hangul`). Nothing is marked text: a run a path ends without replacing
/// is already the host's, so a commit only forgets it.
@MainActor
extension FullKeyboardEngine {
    /// Whether 简体中文 is what types now.
    var composesChinese: Bool { language == .chinese }

    /// A letter key's character through the run. True when it typed a pinyin letter; false
    /// when it isn't one (a mark or a digit, off the letters page too, ends the run with its
    /// first word and types as usual).
    func typePinyin(_ character: String) -> Bool {
        guard composesChinese else { return false }
        guard layerState.layer == .letters, ChinesePinyin.isLetter(character) else {
            pickFirstChineseWord()
            return false
        }
        // A host that moved under the run (a cursor move, a paste, another field's text) ends
        // it: this letter starts a new run where the cursor is now.
        if chinese.hasRun, !chineseRunIsBeforeCursor() {
            chinese.reset()
        }
        insertPinyin(character.lowercased())
        return true
    }

    /// Delete while composing takes the last letter back, the run following the field; the
    /// delete itself then takes the letter out of it.
    func trimChineseRun() {
        guard composesChinese, chinese.hasRun else { return }
        guard chineseRunIsBeforeCursor() else {
            chinese.reset()
            return
        }
        chinese.removeLast()
    }

    /// A page or language switch, emoji, dictation, a pick or a paste: the run's letters are
    /// in the field already, so ending it only forgets them, as Hangul's commit does.
    func commitChineseComposition() {
        guard chinese.hasRun else { return }
        chinese.reset()
    }

    /// A cursor move or a selection: a run the field no longer shows right before the cursor is
    /// the host's text, not a run composing.
    func commitChineseIfHostMoved() {
        guard chinese.hasRun, !chineseRunIsBeforeCursor() else { return }
        chinese.reset()
    }

    /// What the strip shows while pinyin composes: the words the run spells, the likeliest
    /// first — Space puts that one in — and nothing while it spells nothing the dictionary has.
    func chineseSuggestions() -> [KeyboardSuggestion] {
        guard chinese.hasRun else { return [] }
        return chinese.words.enumerated().map { index, word in
            KeyboardSuggestion(
                displayText: word,
                replacement: word,
                kind: index == 0 ? .primary(autoReplace: true) : .secondary
            )
        }
    }

    /// A candidate picked: the word goes in place of the run's letters. What was picked is
    /// learned, so the word comes first the next time its pinyin is typed (Rime's user
    /// dictionary, kept small). A run whose letters the host already took has none to
    /// replace: the word is simply typed where the cursor is.
    func pickChineseWord(_ word: String) {
        guard !word.isEmpty else { return }
        UserWords.shared.learn(word)
        guard chinese.hasRun else {
            insert(word, source: "chinese")
            return
        }
        replaceChineseRun(with: word)
    }

    /// Space, or a mark or return that ends the run: its first word goes in, and no space, as
    /// Apple's Chinese keyboard does. False when no run is composing, so the key acts as usual.
    @discardableResult
    func pickFirstChineseWord() -> Bool {
        guard composesChinese, chinese.hasRun else { return false }
        guard chineseRunIsBeforeCursor() else {
            chinese.reset()
            refreshSuggestions()
            return false
        }
        // A run that spells nothing the dictionary has is kept as it was typed.
        replaceChineseRun(with: chinese.words.first ?? chinese.buffer)
        return true
    }

    /// A pinyin letter typed: as `insert` types a letter, without ending the run.
    private func insertPinyin(_ letter: String) {
        typingLog?.edit("insert", [
            TypingLogField("inserted", .string(letter)),
            TypingLogField("src", .string("pinyin")),
        ])
        rememberTypingContext(before: typingContext, inserted: letter)
        typeIntoField(letter, source: "key")
        lastSpaceAt = nil
        layerState.didInsert(letter)
        rebuildLayoutIfNeeded()
        chinese.type(letter)
        didEdit()
    }

    /// The run's letters in the field replaced by `word`: the letters go, the word takes their
    /// place, and no space follows it.
    private func replaceChineseRun(with word: String) {
        let letters = chinese.buffer
        chinese.reset()
        forgetTypingContext()
        typingLog?.edit("chinese", [
            TypingLogField("deleted", .string(letters)),
            TypingLogField("inserted", .string(word)),
            TypingLogField("src", .string("pinyin")),
        ])
        for _ in 0..<letters.count {
            target.deleteBackward()
        }
        insert(word, source: "chinese")
    }

    /// Whether the run is still the field's at the cursor: nothing selected, and the text
    /// before the cursor ending with its letters.
    private func chineseRunIsBeforeCursor() -> Bool {
        guard chinese.hasRun else { return false }
        guard (target.selectedText ?? "").isEmpty else { return false }
        guard let before = typingContext ?? textBefore else { return false }
        return before.hasSuffix(chinese.buffer)
    }
}
