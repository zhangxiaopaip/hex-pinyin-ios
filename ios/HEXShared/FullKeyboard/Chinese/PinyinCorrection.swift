import Foundation

/// The pinyin a typo probably meant.
///
/// A dictionary that answers exact spellings only leaves a mistyped run with nothing at all:
/// "zhagn" spells no word, though the hand that meant 张 is one swapped pair away. The pairs
/// Chinese speakers type for each other are few — 平舌 and 翘舌 (zh/z, ch/c, sh/s), n and l,
/// and the finals that differ only in the nose — and a swap of two letters is the other slip
/// a fast thumb makes. Each near key carries what reading it costs, so an exact spelling
/// always stands ahead of a repaired one.
nonisolated enum PinyinCorrection {
    /// What reading a near key costs a candidate: a guess, where an exact spelling is not.
    static let fuzzyCost: Double = 2
    /// A pair of letters typed the wrong way round: likelier than a wrong initial, still a guess.
    static let swapCost: Double = 2.6

    /// The initials typed for each other: written, meant.
    private static let initials: [(written: String, meant: String)] = [
        ("zh", "z"), ("ch", "c"), ("sh", "s"), ("n", "l"),
    ]

    /// The finals that differ only in the nose: written, meant.
    private static let finals: [(written: String, meant: String)] = [
        ("iang", "ian"), ("uang", "uan"), ("ang", "an"), ("eng", "en"), ("ing", "in"),
    ]

    /// The keys `key` may have been meant as, and what reading each costs. A pinyin syllable is
    /// at most six letters, so a key longer than ten is a word's worth of them and is left be.
    static func near(_ key: String) -> [(key: String, cost: Double)] {
        guard key.count >= 2, key.count <= 10 else { return [] }
        var out: [(key: String, cost: Double)] = []
        for pair in initials {
            if key.hasPrefix(pair.written), key.count > pair.written.count {
                out.append((pair.meant + String(key.dropFirst(pair.written.count)), fuzzyCost))
            } else if key.hasPrefix(pair.meant), key.count > pair.meant.count {
                out.append((pair.written + String(key.dropFirst(pair.meant.count)), fuzzyCost))
            }
        }
        for pair in finals {
            if key.hasSuffix(pair.written), key.count > pair.written.count {
                out.append((String(key.dropLast(pair.written.count)) + pair.meant, fuzzyCost))
            } else if key.hasSuffix(pair.meant), key.count > pair.meant.count {
                out.append((String(key.dropLast(pair.meant.count)) + pair.written, fuzzyCost))
            }
        }
        let letters = Array(key)
        let last = letters.count - 1
        if letters.count >= 3, letters[last] != letters[last - 1] {
            var swapped = letters
            swapped.swapAt(last, last - 1)
            out.append((String(swapped), swapCost))
        }
        var seen: Set<String> = [key]
        return out.filter { seen.insert($0.key).inserted }
    }

    /// `letters` with every letter typed twice taken once: no pinyin syllable doubles a letter,
    /// so "nihhaoo" is "nihao" and nothing else.
    static func collapsingDoubles(_ letters: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(letters.count)
        for letter in letters where out.last != letter {
            out.append(letter)
        }
        return out
    }
}
