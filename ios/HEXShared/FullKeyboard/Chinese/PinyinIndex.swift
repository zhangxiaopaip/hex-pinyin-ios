import Foundation

/// 万象拼音's index on disk, as `ios/scripts/build-wanxiang-dictionary.py` writes it: mapped
/// read-only, little-endian, one bucket per first letter and a binary search inside it.
///
/// ```
/// header  : "HXWX" | u16 version | u32 fullTable | u32 abbrevTable | u32 totalWeight
///           | u32 prefixTable
/// table   : 26 × (u32 offset, u32 size)      // an entry per initial letter
/// bucket  : u32 count | (count + 1) × u32 offsets, relative to the bucket
///           | count × (u8 keyLength, key | u16 wordCount, wordCount × (u8 len, text, u32 weight))
/// ```
///
/// It lives apart from `PinyinDictionary` so a plain `swiftc` build can check it against the
/// shipped file (`ios/scripts/verify-pinyin-index.swift`), which is how the field that emptied
/// every lookup got found: the table's second word is the bucket's size in bytes, and reading
/// it as a record count made the search probe past the last record and give up.
nonisolated final class PinyinIndex: @unchecked Sendable {
    struct Entry: Equatable {
        let text: String
        let weight: UInt32
    }

    enum Table {
        case full
        case abbrev
        case prefix
    }

    private let mapping: UnsafeRawBufferPointer?
    private let mapSize: Int
    private let fullTableAt: Int
    private let abbrevTableAt: Int
    private let prefixTableAt: Int
    /// The corpus's total weight, for a unigram score: `log(share)`.
    let totalWeight: UInt32

    // MARK: - Loading

    init?(fileURL: URL) {
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
        guard bytes.count > 26,
              bytes[0] == 0x48, bytes[1] == 0x58, bytes[2] == 0x57, bytes[3] == 0x58 else {
            munmap(pointer, Int(size))
            return nil
        }
        self.mapping = bytes
        self.mapSize = Int(size)
        self.fullTableAt = Int(Self.u32(bytes, 6))
        self.abbrevTableAt = Int(Self.u32(bytes, 10))
        self.totalWeight = Self.u32(bytes, 14)
        // Version 2 added the half-syllable table at the header's end.
        self.prefixTableAt = bytes.count > 26 ? Int(Self.u32(bytes, 18)) : 0
    }

    /// A dictionary with no file: every lookup is empty, and `isLoaded` says so.
    init(empty: ()) {
        self.mapping = nil
        self.mapSize = 0
        self.fullTableAt = 0
        self.abbrevTableAt = 0
        self.prefixTableAt = 0
        self.totalWeight = 1
    }

    deinit {
        guard let base = mapping?.baseAddress, mapSize > 0 else { return }
        munmap(UnsafeMutableRawPointer(mutating: base), mapSize)
    }

    var isLoaded: Bool { mapping != nil }

    // MARK: - Reading

    private static func u32(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private func tableOffset(_ table: Table) -> Int {
        switch table {
        case .full: fullTableAt
        case .abbrev: abbrevTableAt
        case .prefix: prefixTableAt
        }
    }

    /// How many keys a first letter holds in a table: 0 where the letter starts no syllable
    /// at all (i, u and v are spelled yi, wu and yu).
    func recordCount(for letter: Character, in table: Table = .full) -> Int {
        guard let bucket = bucket(for: letter, in: table) else { return 0 }
        return bucket.count
    }

    /// Where a first letter's bucket starts, and how many keys it holds.
    ///
    /// The table's second word is the bucket's **size in bytes**, not its record count: the
    /// count opens the bucket's body, after which come the records' offsets. Reading the size
    /// as a count made the binary search start far past the last record and give up on its
    /// first probe, so every lookup — every pinyin, every prefix — came back empty and the
    /// keyboard offered no candidates at all.
    private func bucket(for letter: Character, in table: Table) -> (start: Int, count: Int)? {
        guard let mapping, let ascii = letter.asciiValue, ascii >= 97, ascii <= 122 else { return nil }
        let base = tableOffset(table)
        guard base > 0 else { return nil }
        let entryAt = base + Int(ascii - 97) * 8
        guard entryAt + 8 <= mapping.count else { return nil }
        let start = Int(Self.u32(mapping, entryAt))
        guard start >= 4, start + 4 <= mapping.count else { return nil }
        let count = Int(Self.u32(mapping, start))
        guard count > 0 else { return nil }
        return (start, count)
    }

    /// Every record whose key is `key` exactly, in the order the file holds them.
    func entries(for key: String, in table: Table = .full) -> [Entry] {
        guard let mapping, !key.isEmpty, let first = key.first else { return [] }
        let wanted = Array(key.utf8)
        guard let bucket = bucket(for: first, in: table) else { return [] }
        let start = bucket.start
        let count = bucket.count

        var low = 0
        var high = count - 1
        while low <= high {
            let middle = (low + high) / 2
            let offsetsAt = start + 4 + middle * 4
            guard offsetsAt + 4 <= mapping.count else { return [] }
            let recordAt = start + Int(Self.u32(mapping, offsetsAt))
            guard recordAt > start, recordAt < mapping.count else { return [] }
            let keyLength = Int(mapping[recordAt])
            guard recordAt + 1 + keyLength <= mapping.count else { return [] }
            let order = compare(mapping, from: recordAt + 1, length: keyLength, against: wanted)
            if order == 0 { return words(at: recordAt, in: mapping) }
            if order < 0 { low = middle + 1 } else { high = middle - 1 }
        }
        return []
    }

    /// How a record's key orders against `wanted`: -1 before, 0 equal, 1 after.
    private func compare(
        _ mapping: UnsafeRawBufferPointer,
        from start: Int,
        length: Int,
        against wanted: [UInt8]
    ) -> Int {
        var index = 0
        while index < length && index < wanted.count {
            let left = mapping[start + index]
            if left != wanted[index] { return left < wanted[index] ? -1 : 1 }
            index += 1
        }
        if length == wanted.count { return 0 }
        return length < wanted.count ? -1 : 1
    }

    private func words(at record: Int, in mapping: UnsafeRawBufferPointer) -> [Entry] {
        var cursor = record + 1 + Int(mapping[record])
        guard cursor + 2 <= mapping.count else { return [] }
        let count = Int(mapping[cursor]) | Int(mapping[cursor + 1]) << 8
        cursor += 2
        var out: [Entry] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard cursor < mapping.count else { break }
            let length = Int(mapping[cursor])
            cursor += 1
            guard cursor + length + 4 <= mapping.count else { break }
            let text = String(decoding: mapping[cursor..<(cursor + length)], as: UTF8.self)
            cursor += length
            out.append(Entry(text: text, weight: Self.u32(mapping, cursor)))
            cursor += 4
        }
        return out
    }
}
