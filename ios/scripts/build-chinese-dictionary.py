#!/usr/bin/env python3
"""Builds HEXShared/FullKeyboard/Chinese/PinyinDictionary.tsv, the pinyin input's words.

Inputs (downloaded once, kept out of the tree):

- mozillazg/pinyin-data (MIT) pinyin.txt: every character's readings, commonest first
  (`U+4E00: yī  # 一`).
- mozillazg/phrase-pinyin-data (MIT) pinyin.txt: phrases with their readings, which is
  where a polyphonic character's reading in a word comes from (`重要: zhòng yào`).
- fxsjy/jieba (MIT) dict.txt: words with corpus frequencies, which rank the candidates
  and give the characters their frequencies.

    curl -LO https://raw.githubusercontent.com/mozillazg/pinyin-data/master/pinyin.txt
    curl -LO https://raw.githubusercontent.com/mozillazg/phrase-pinyin-data/master/pinyin.txt
    curl -LO https://raw.githubusercontent.com/fxsjy/jieba/master/jieba/dict.txt
    python3 ios/scripts/build-chinese-dictionary.py pinyin.txt phrase.txt dict.txt \\
        > ios/HEXShared/FullKeyboard/Chinese/PinyinDictionary.tsv

The output is `pinyin<TAB>text<TAB>frequency`, one entry a line, pinyin without tones or
spaces ("nihaoma"), then a `# total:` line the ranking reads (the corpus's token count,
which turns the frequencies into a unigram model over words).
"""

import re
import sys
import unicodedata

# What Hex types: only characters a Chinese keyboard needs.
CJK = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]")

# The corpus' own segmentation of a phrase into chars is not needed: a phrase's pinyin is
# its characters' syllables run together, which is what the keyboard reads.
TONE_MARKS = {
    "ā": "a", "á": "a", "ǎ": "a", "à": "a",
    "ē": "e", "é": "e", "ě": "e", "è": "e",
    "ī": "i", "í": "i", "ǐ": "i", "ì": "i",
    "ō": "o", "ó": "o", "ǒ": "o", "ò": "o",
    "ū": "u", "ú": "u", "ǔ": "u", "ù": "u",
    "ǖ": "v", "ǘ": "v", "ǚ": "v", "ǜ": "v", "ü": "v",
    "ń": "n", "ň": "n", "ǹ": "n",
    "ḿ": "m", "ê": "e", "ā": "a",
}


def plain(syllable: str) -> str:
    """A syllable without its tone: "zhòng" -> "zhong", "lǜ" -> "lv"."""
    out = []
    for char in syllable:
        # ü is a letter of its own, not u with a mark: the keyboard's ü key types v.
        if char in "üǖǘǚǜ":
            out.append("v")
            continue
        lowered = char.lower()
        if lowered in TONE_MARKS:
            out.append(TONE_MARKS[lowered])
            continue
        if unicodedata.combining(char):
            continue
        out.append(lowered)
    return "".join(out)


def read_characters(path: str) -> dict[str, list[str]]:
    """Every character's readings, commonest first ("一" -> ["yi"])."""
    readings: dict[str, list[str]] = {}
    with open(path, encoding="utf-8") as file:
        for line in file:
            if line.startswith("#") or ":" not in line:
                continue
            code, rest = line.split(":", 1)
            text = rest.split("#", 1)[0].strip()
            if not text:
                continue
            try:
                char = chr(int(code.strip()[2:], 16))
            except ValueError:
                continue
            if not CJK.fullmatch(char):
                continue
            syllables = [plain(part) for part in text.split(",")]
            readings[char] = [s for s in syllables if s]
    return readings


def read_phrases(path: str) -> dict[str, str]:
    """Phrases with their readings run together ("重要" -> "zhongyao")."""
    phrases: dict[str, str] = {}
    with open(path, encoding="utf-8") as file:
        for line in file:
            if line.startswith("#") or ":" not in line:
                continue
            word, rest = line.split(":", 1)
            word = word.strip()
            if len(word) < 2 or not all(CJK.fullmatch(char) for char in word):
                continue
            syllables = [plain(part) for part in rest.split()]
            if not all(syllables):
                continue
            phrases[word] = "".join(syllables)
    return phrases


def read_words(path: str) -> dict[str, float]:
    """Words with their corpus frequencies."""
    words: dict[str, float] = {}
    with open(path, encoding="utf-8") as file:
        for line in file:
            parts = line.split()
            if len(parts) < 2:
                continue
            word, freq = parts[0], parts[1]
            if not all(CJK.fullmatch(char) for char in word):
                continue
            try:
                words[word] = float(freq)
            except ValueError:
                continue
    return words


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    readings = read_characters(argv[1])
    phrases = read_phrases(argv[2])
    words = read_words(argv[3])

    # The token count the frequencies are shares of: every word of the corpus, and every
    # character typed on its own. `# total:` then lets a candidate's score be its words'
    # shares multiplied together, which is what ranks a longer word over its parts.
    total = sum(words.values()) + sum(words.get(char, 0.0) for char in readings)

    # A character's corpus count counts it wherever it appears, inside words too; typed as a
    # word of its own it is rarer, and a phrase would lose to its characters ("再见" to "在"
    # and "见"): the count is scaled down to what the character is worth on its own.
    CHAR_SHARE = 0.15
    # The corpus' least common words are the ones nobody types; composing them from their
    # characters still gets them.
    MIN_WORD_FREQ = {2: 40, 3: 25, 4: 15}

    entries: list[tuple[str, str, float]] = []
    for char, syllables in readings.items():
        freq = words.get(char, 0.0) * CHAR_SHARE
        if freq <= 0:
            continue
        for index, syllable in enumerate(syllables[:4]):
            # The commonest reading is the character's own share; the others are rarer, so
            # they stand behind it when both spell a word.
            entries.append((syllable, char, freq if index == 0 else freq * 0.4))

    def spelled(word: str) -> str:
        """The word's pinyin: the phrase list's where it has it (which knows a polyphonic
        character's reading there), else its characters' commonest ones."""
        if word in phrases:
            return phrases[word]
        return "".join(readings.get(char, [""])[0] for char in word)

    for word, freq in words.items():
        if not 2 <= len(word) <= 4 or freq < MIN_WORD_FREQ[len(word)]:
            continue
        pinyin = spelled(word)
        if not pinyin.isalpha():
            continue
        entries.append((pinyin, word, freq))

    # Phrases the corpus doesn't know add nothing the characters can't spell, and the
    # phrase list's long tail is mostly classical Chinese: left out.

    # Several readings of one character can spell the same pinyin ("啊" a, á, ǎ, à): one
    # entry, its best frequency.
    best: dict[tuple[str, str], float] = {}
    for pinyin, word, freq in entries:
        key = (pinyin, word)
        if freq > best.get(key, 0.0):
            best[key] = freq
    entries = [(pinyin, word, freq) for (pinyin, word), freq in best.items()]
    entries.sort(key=lambda entry: (entry[0], -entry[2]))
    out = sys.stdout
    out.write("# Hex's Chinese keyboard: pinyin (no tones, no spaces), the word, its frequency.\n")
    out.write("# Built by ios/scripts/build-chinese-dictionary.py from pinyin-data, phrase-pinyin-data\n")
    out.write("# and jieba's dictionary, all MIT. Do not edit by hand.\n")
    out.write(f"# total: {int(total)}\n")
    for pinyin, word, freq in entries:
        out.write(f"{pinyin}\t{word}\t{int(freq)}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
