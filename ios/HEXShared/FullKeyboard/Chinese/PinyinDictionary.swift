import Foundation

/// Reads the little-endian u32 the index stores at `offset`.
private func hexU32(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
    guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
    return UInt32(bytes[offset])
        | UInt32(bytes[offset + 1]) << 8
        | UInt32(bytes[offset + 2]) << 16
        | UInt32(bytes[offset + 3]) << 24
}

/// The Chinese keyboard's words, built from 万象拼音 (a Rime schema,
/// https://github.com/amzxyz/rime-wanxiang) into `Wanxiang.pinyin` by
/// `ios/scripts/build-wanxiang-dictionary.py`.
///
/// The file is memory-mapped and decoded one pinyin at a time: a 400,000-word dictionary
/// costs a mapped file and the few pages it reads, not tens of megabytes of Swift strings —
/// which is what a keyboard extension's memory limit makes a difference about. A lookup is a
/// binary search inside the first letter's bucket, so typing stays cheap however large the
/// dictionary is.
///
/// A candidate's score is a unigram model over words, as Rime's is: the sum of the log shares
/// of the corpus, so a word beats the characters it is made of ("你好" over "你" and "好") and
/// a run several words long is read as words ("jintiantianqi" -> 今天天气).
nonisolated final class PinyinDictionary: @unchecked Sendable {
    /// One word and its share of the corpus.
    struct Word: Sendable, Equatable {
        let text: String
        let weight: Double
        var logWeight: Double { log(max(weight, 1)) }
    }

    /// Read once per process: the first pinyin letter typed pays for the map.
    static let shared = PinyinDictionary.bundled()

    /// How many paths a run keeps per position: enough for every reading of a long run.
    private static let beam = 32
    /// How many half-typed syllables, and words of each, a run's end offers.
    private static let partials = 12
    /// What a half-typed syllable costs a candidate: it may still turn into another word.
    private static let partialPenalty = 1.5
    /// What a 简拼 (initials-only) reading costs: it is a guess, where a full pinyin is not.
    private static let abbrevPenalty = 2.5
    /// The longest key a single step can use, which bounds a lookup's steps.
    private static let maxKeyLength = 24
    /// The longest beginning of a pinyin the half-syllable table holds ("nih", not "nihao").
    private static let maxPrefixLength = 3
    /// Cached lookups: typing and deleting revisit the same keys constantly.
    private static let cacheLimit = 512

    private let mapping: UnsafeRawBufferPointer?
    private let mapSize: Int
    private let fullTableAt: Int
    private let abbrevTableAt: Int
    /// The words a half-typed syllable may become. 0 in a version 1 file, which had none.
    private let prefixTableAt: Int
    private let logTotal: Double

    private let lock = NSLock()
    private var cache: [String: [Word]] = [:]

    // MARK: - Loading

    private static func bundled() -> PinyinDictionary {
        var candidates: [URL] = []
        if let url = Bundle.main.url(forResource: "Wanxiang", withExtension: "pinyin") {
            candidates.append(url)
        }
        // The app previews 简体中文 from the extension's dictionary: the appex ships it, not
        // the app (project.yml excludes it there).
        if let plugins = Bundle.main.builtInPlugInsURL,
           let keyboard = Bundle(url: plugins.appendingPathComponent("HEXKeyboard.appex")),
           let url = keyboard.url(forResource: "Wanxiang", withExtension: "pinyin") {
            candidates.append(url)
        }
        for url in candidates {
            if let dictionary = PinyinDictionary(fileURL: url) { return dictionary }
        }
        // No dictionary in the bundle: the keys keep the pinyin as typed and offer no word,
        // which is a visible failure rather than a silent wrong one.
        return PinyinDictionary(empty: ())
    }

    /// Maps the file read-only: pages arrive as they are read, and the mapping lives as long
    /// as the keyboard process does.
    private init?(fileURL: URL) {
        let descriptor = open(fileURL.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        let size = lseek(descriptor, 0, SEEK_END)
        guard size > 64 else { close(descriptor); return nil }
        guard let pointer = mmap(nil, Int(size), PROT_READ, MAP_PRIVATE, descriptor, 0),
              pointer != MAP_FAILED else {
            close(descriptor)
            return nil
        }
        close(descriptor)
        let bytes = UnsafeRawBufferPointer(start: pointer, count: Int(size))
        guard bytes.count > 32,
              bytes[0] == 0x48, bytes[1] == 0x58, bytes[2] == 0x57, bytes[3] == 0x58 else {
            munmap(pointer, Int(size))
            return nil
        }
        self.mapping = bytes
        self.mapSize = Int(size)
        self.fullTableAt = Int(hexU32(bytes, 6))
        self.abbrevTableAt = Int(hexU32(bytes, 10))
        // Version 2 added the half-syllable table at the header's end.
        self.prefixTableAt = bytes.count > 26 ? Int(hexU32(bytes, 18)) : 0
        self.logTotal = log(max(Double(hexU32(bytes, 14)), 2))
    }

    private init(empty: ()) {
        self.mapping = nil
        self.mapSize = 0
        self.fullTableAt = 0
        self.abbrevTableAt = 0
        self.prefixTableAt = 0
        self.logTotal = 1
    }

    deinit {
        guard let base = mapping?.baseAddress, mapSize > 0 else { return }
        munmap(UnsafeMutableRawPointer(mutating: base), mapSize)
    }

    // MARK: - Reading the index

    /// Where a first letter's bucket starts, and how many keys it holds.
    private func bucket(at table: Int, letter: UInt8) -> (start: Int, count: Int)? {
        guard let mapping, letter >= 97, letter <= 122 else { return nil }
        let entry = table + Int(letter - 97) * 8
        guard entry + 8 <= mapping.count else { return nil }
        let count = Int(hexU32(mapping, entry + 4))
        guard count > 0 else { return nil }
        return (Int(hexU32(mapping, entry)), count)
    }

    /// A record's offset for a bucket index.
    private func record(_ index: Int, in bucket: (start: Int, count: Int)) -> Int? {
        guard let mapping else { return nil }
        let at = bucket.start + 4 + index * 4
        guard at + 4 <= mapping.count else { return nil }
        let offset = Int(hexU32(mapping, at))
        guard offset > 0, bucket.start + offset < mapping.count else { return nil }
        return bucket.start + offset
    }

    /// How a record's key orders against `wanted`: -1 before, 0 equal, 1 after.
    private func order(of record: Int, against wanted: [UInt8]) -> Int? {
        guard let mapping, record >= 0, record < mapping.count else { return nil }
        let length = Int(mapping[record])
        let start = record + 1
        guard start + length <= mapping.count else { return nil }
        var index = 0
        while index < length && index < wanted.count {
            let left = mapping[start + index]
            if left != wanted[index] { return left < wanted[index] ? -1 : 1 }
            index += 1
        }
        if length == wanted.count { return 0 }
        return length < wanted.count ? -1 : 1
    }

    /// Every word a pinyin spells, the likeliest first.
    func words(for key: String) -> [Word] {
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()

        let found = lookup(key, at: fullTableAt)

        lock.lock()
        if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = found
        lock.unlock()
        return found
    }

    private func lookup(_ key: String, at table: Int) -> [Word] {
        let wanted = Array(key.utf8)
        guard let first = wanted.first, let bucket = bucket(at: table, letter: first) else { return [] }

        var low = 0
        var high = bucket.count - 1
        while low <= high {
            let middle = (low + high) / 2
            guard let at = record(middle, in: bucket), let order = order(of: at, against: wanted) else { return [] }
            if order == 0 { return words(at: at) }
            if order < 0 { low = middle + 1 } else { high = middle - 1 }
        }
        return []
    }

    private func words(at record: Int) -> [Word] {
        guard let mapping else { return [] }
        var cursor = record
        let keyLength = Int(mapping[cursor])
        cursor += 1 + keyLength
        guard cursor + 2 <= mapping.count else { return [] }
        let count = Int(mapping[cursor]) | Int(mapping[cursor + 1]) << 8
        cursor += 2
        var out: [Word] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard cursor < mapping.count else { break }
            let length = Int(mapping[cursor])
            cursor += 1
            guard cursor + length + 4 <= mapping.count else { break }
            let text = String(decoding: mapping[cursor..<(cursor + length)], as: UTF8.self)
            cursor += length
            let weight = Double(hexU32(mapping, cursor))
            cursor += 4
            out.append(Word(text: text, weight: weight))
        }
        return out
    }

    /// The likeliest words whose pinyin starts with `prefix`, for a half-typed syllable
    /// ("w" -> 我, "sh" -> 是, "nih" -> 你好): a table of its own, so no scanning of keys.
    private func wordsStarting(with prefix: String, limit: Int) -> [Word] {
        guard prefixTableAt > 0, prefix.count <= Self.maxPrefixLength else { return [] }
        return Array(lookup(prefix, at: prefixTableAt).prefix(limit))
    }

    // MARK: - Candidates

    /// The words `input` (pinyin letters, no tones, no spaces) spells, the likeliest first:
    /// a word's pinyin run together, several words in a run, half a syllable at the run's end
    /// ("nih" -> 你好), and 简拼 initials ("nh" -> 你好).
    func candidates(for input: String, limit: Int = 3) -> [String] {
        let letters = Array(input.lowercased().utf8)
        guard !letters.isEmpty, letters.count <= 40, limit > 0 else { return [] }
        guard letters.allSatisfy({ $0 >= 97 && $0 <= 122 }) else { return [] }

        struct Path {
            let score: Double
            let text: String
        }

        var best: [[Path]] = Array(repeating: [], count: letters.count + 1)
        best[0] = [Path(score: 0, text: "")]

        for position in 0..<letters.count {
            guard !best[position].isEmpty else { continue }
            let paths = best[position].sorted { $0.score > $1.score }.prefix(Self.beam)
            let remaining = letters.count - position
            for path in paths {
                for length in 1...min(Self.maxKeyLength, remaining) {
                    let key = String(decoding: letters[position..<(position + length)], as: UTF8.self)
                    let matched = words(for: key)
                    guard !matched.isEmpty else { continue }
                    for word in matched {
                        best[position + length].append(
                            Path(score: path.score + word.logWeight - logTotal, text: path.text + word.text)
                        )
                    }
                }
            }
            // A run's later letters only ever add to a path, so the likeliest few of each
            // position stand for the rest.
            for target in (position + 1)...letters.count where best[target].count > Self.beam * 8 {
                best[target] = Array(best[target].sorted { $0.score > $1.score }.prefix(Self.beam))
            }
        }

        var found = best[letters.count]

        // Half a syllable at the end: the words it may yet become, behind the ones it spells
        // ("nih" -> 你好). A tail that already spells something is spelled above, and a single
        // letter is only guessed at when nothing spells the run, so "zhang" is not padded with
        // 展改 and 战该 — while "zhongg" still reads as 中 and the letter it ends on.
        let spellsTheRun = !best[letters.count].isEmpty
        for position in 0..<letters.count where !best[position].isEmpty {
            let tail = String(decoding: letters[position...], as: UTF8.self)
            guard tail.count <= 6, tail.count >= 2 || !spellsTheRun else { continue }
            guard words(for: tail).isEmpty else { continue }
            for word in wordsStarting(with: tail, limit: Self.partials) {
                for path in best[position].sorted { $0.score > $1.score }.prefix(Self.partials) {
                    found.append(
                        Path(score: path.score + word.logWeight - logTotal - Self.partialPenalty,
                             text: path.text + word.text)
                    )
                }
            }
        }

        // 简拼: initials only ("nh", "zg"), which Rime offers beside the full spelling.
        let initials = String(decoding: letters, as: UTF8.self)
        if initials.count >= 2, initials.count <= 6 {
            for word in lookup(initials, at: abbrevTableAt) {
                found.append(Path(score: word.logWeight - logTotal - Self.abbrevPenalty, text: word.text))
            }
        }

        // The typist's own picks move up: what they chose before is what they mean now.
        let learned = UserWords.shared
        // A syllable typed whole leads with the characters it spells, as Apple's keyboard
        // does ("zhang" -> 张 长 章 涨 …, then 障碍, 长大), instead of putting whichever
        // phrase is commoner than the character first.
        let characters = Set(words(for: input).lazy.filter { $0.text.count == 1 }.map(\.text))
        let scored = found.map { path in
            Path(score: path.score + learned.boost(for: path.text), text: path.text)
        }.sorted { left, right in
            let leftIsCharacter = characters.contains(left.text)
            let rightIsCharacter = characters.contains(right.text)
            if leftIsCharacter != rightIsCharacter { return leftIsCharacter }
            return left.score > right.score
        }

        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(min(limit, scored.count))
        for path in scored {
            guard seen.insert(path.text).inserted else { continue }
            out.append(path.text)
            if out.count == limit { break }
        }
        return out
    }
}

/// The words the typist picked, so a word typed before comes first: Rime's user dictionary,
/// kept small and in the keyboard's own defaults.
nonisolated final class UserWords: @unchecked Sendable {
    static let shared = UserWords()

    private let lock = NSLock()
    private var counts: [String: Int]
    private let defaults = KeyboardBridge.storage ?? .standard
    private static let key = "chinese.userWords"

    private init() {
        counts = (defaults.dictionary(forKey: Self.key) as? [String: Int]) ?? [:]
    }

    /// How far a word's own history lifts it: enough to win against a word of similar
    /// frequency, never against one far commoner.
    func boost(for word: String) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let count = counts[word], count > 0 else { return 0 }
        return min(1.5 + log(Double(count) + 1), 6)
    }

    func learn(_ word: String) {
        guard !word.isEmpty, word.count <= 8 else { return }
        lock.lock()
        counts[word, default: 0] += 1
        if counts.count > 2_000 {
            counts = counts.sorted { $0.value > $1.value }.prefix(1_000)
                .reduce(into: [String: Int]()) { $0[$1.key] = $1.value }
        }
        let snapshot = counts
        lock.unlock()
        defaults.set(snapshot, forKey: Self.key)
    }
}
