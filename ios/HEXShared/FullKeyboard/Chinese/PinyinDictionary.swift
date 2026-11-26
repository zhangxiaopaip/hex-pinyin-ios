import Foundation

/// The Chinese keyboard's words by pinyin, read from `PinyinDictionary.tsv` in the keyboard's
/// bundle (the app's for its keyboard preview), which `scripts/build-chinese-dictionary.py`
/// builds from pinyin-data, phrase-pinyin-data and jieba's dictionary. It is a unigram model
/// over words: a candidate's score is the product of its words' shares of the corpus, so a
/// word beats the characters it is made of ("你好" over "你" and "好").
nonisolated struct PinyinDictionary: Sendable {
    /// One word and how often the corpus has it.
    struct Word: Sendable, Equatable {
        let text: String
        let frequency: Double
    }

    /// Words by their pinyin run together ("nihao"), the commonest first.
    private let words: [String: [Word]]
    /// Every pinyin with its commonest word, likeliest first, in buckets by the pinyin's first
    /// letter so a half-typed syllable at the run's end is completed by the words it may become
    /// rather than the alphabet's first ones ("zh" -> 这, 中, 着, not 炸弹) without reading all
    /// 49,000 of them for each letter typed.
    private let completions: [Character: [(pinyin: String, word: Word)]]
    /// The log of the corpus' words, which a word's frequency is a count out of.
    private let logTotal: Double
    /// The longest pinyin of any word, which bounds a lookup's steps.
    private let longestPinyin: Int

    /// Read once per process: the first pinyin letter typed pays for it.
    static let shared = PinyinDictionary.bundled()

    /// How many paths a run keeps per position: enough for every reading of a long run.
    private static let beam = 32
    /// How many half-typed syllables, and words of each, a run's end offers.
    private static let partials = 6
    /// What a half-typed syllable costs a candidate: it may still turn into another word.
    private static let partialPenalty = 1.5
    /// A pinyin no word has, so a pinyin's words stay a few and a lookup stays cheap.
    private static let wordsPerPinyin = 8

    private init(words: [String: [Word]], logTotal: Double, longestPinyin: Int) {
        self.words = words
        // Likeliest first, then kept in buckets by the pinyin's first letter: a bucket is still
        // in that order, so taking a prefix's first few words from the one bucket the prefix
        // starts in reads the same words as reading every pinyin would.
        var completions: [Character: [(pinyin: String, word: Word)]] = [:]
        let likeliest = words
            .compactMap { pinyin, list in list.first.map { (pinyin: pinyin, word: $0) } }
            .sorted { $0.word.frequency > $1.word.frequency }
        for entry in likeliest {
            guard let initial = entry.pinyin.first else { continue }
            completions[initial, default: []].append(entry)
        }
        self.completions = completions
        self.logTotal = logTotal
        self.longestPinyin = longestPinyin
    }

    /// The dictionary in the bundle, or an empty one when the build has none: then the keys
    /// keep the pinyin as it is typed and every word comes from its characters.
    static func bundled() -> PinyinDictionary {
        var url = Bundle.main.url(forResource: "PinyinDictionary", withExtension: "tsv")
        if url == nil, let plugins = Bundle.main.builtInPlugInsURL,
           let keyboard = Bundle(url: plugins.appendingPathComponent("HEXKeyboard.appex")) {
            url = keyboard.url(forResource: "PinyinDictionary", withExtension: "tsv")
        }
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return empty }
        return parse(text)
    }

    private static let empty = PinyinDictionary(words: [:], logTotal: 1, longestPinyin: 1)

    /// `pinyin<TAB>word<TAB>frequency` lines, then the header's `# total:` line.
    static func parse(_ text: String) -> PinyinDictionary {
        var words: [String: [Word]] = [:]
        var total = 1.0
        var longest = 1
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") {
                let header = String(line.dropFirst())
                if header.hasPrefix(" total:"),
                   let value = Double(String(header.dropFirst(" total:".count)).trimmingCharacters(in: .whitespaces)) {
                    total = value
                }
                continue
            }
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 3, let frequency = Double(parts[2]) else { continue }
            let pinyin = String(parts[0])
            let word = String(parts[1])
            guard !pinyin.isEmpty, !word.isEmpty else { continue }
            words[pinyin, default: []].append(Word(text: word, frequency: frequency))
            longest = max(longest, pinyin.count)
        }
        for pinyin in Array(words.keys) {
            words[pinyin] = words[pinyin].map { Array($0.prefix(Self.wordsPerPinyin)) }
        }
        return PinyinDictionary(
            words: words,
            logTotal: log(max(total, 2)),
            longestPinyin: min(longest, 32)
        )
    }

    /// The words `input` (pinyin letters, no tones, no spaces) spells, the likeliest first: a
    /// word's pinyin run together, or half a syllable at the run's end ("nih" -> "你好").
    func candidates(for input: String, limit: Int = 3) -> [String] {
        let letters = Array(input.lowercased())
        guard !letters.isEmpty, letters.count <= 32 else { return [] }

        /// One reading of the run so far: its words, and how likely together.
        struct Path {
            let score: Double
            let text: String
        }

        var best: [Int: [Path]] = [0: [Path(score: 0, text: "")]]
        for position in 0..<letters.count {
            guard let paths = best[position], !paths.isEmpty else { continue }
            for path in paths.prefix(Self.beam) {
                let remaining = letters.count - position
                for length in 1...min(longestPinyin, remaining) {
                    let pinyin = String(letters[position..<(position + length)])
                    guard let matches = words[pinyin] else { continue }
                    for word in matches {
                        let score = path.score + log(max(word.frequency, 1)) - logTotal
                        best[position + length, default: []].append(
                            Path(score: score, text: path.text + word.text)
                        )
                    }
                }
            }
            // A run's later letters only ever add to a path, so the likeliest few of each
            // position stand for the rest.
            for target in Array(best.keys) where target > position && (best[target]?.count ?? 0) > Self.beam * 2 {
                best[target] = best[target].map { Array($0.sorted { $0.score > $1.score }.prefix(Self.beam)) }
            }
        }

        var found = best[letters.count] ?? []
        // Half a syllable at the end: the words it may yet become, behind the ones it spells.
        for position in Array(best.keys) where position < letters.count {
            let tail = String(letters[position...])
            guard !tail.isEmpty, let paths = best[position], !paths.isEmpty else { continue }
            for word in wordsStarting(with: tail, limit: Self.partials) {
                for path in paths.prefix(Self.partials) {
                    let score = path.score + log(max(word.frequency, 1)) - logTotal - Self.partialPenalty
                    found.append(Path(score: score, text: path.text + word.text))
                }
            }
        }

        var seen = Set<String>()
        var out: [String] = []
        for path in found.sorted(by: { $0.score > $1.score }) {
            guard seen.insert(path.text).inserted else { continue }
            out.append(path.text)
            if out.count == limit { break }
        }
        return out
    }

    /// The likeliest words whose pinyin starts with `prefix`, for a half-typed syllable.
    private func wordsStarting(with prefix: String, limit: Int) -> [Word] {
        guard let initial = prefix.first else { return [] }
        var out: [Word] = []
        for entry in completions[initial] ?? [] where entry.pinyin.hasPrefix(prefix) {
            out.append(entry.word)
            if out.count == limit { break }
        }
        return out
    }
}
