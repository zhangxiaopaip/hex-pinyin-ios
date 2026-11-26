#!/usr/bin/env python3
"""Builds the Chinese keyboard's dictionary from 万象拼音 (Rime) into
Wanxiang.pinyin, the compact index PinyinDictionary.swift memory-maps.

Source: https://github.com/amzxyz/rime-wanxiang
        dicts/{zi,jichu,duoyin,diming,mingren,yiren}.dict.yaml
Line format: <word>TAB<syllables, space separated>TAB<weight>

Output layout (little endian):

  magic "HXWX" | u16 version | u32 fullTable | u32 abbrevTable | u32 totalWeight
  | u32 prefixTable
  table (×3): 26 × (u32 offset, u32 length)   // one bucket per initial letter
  blobs     : bucket bodies

  bucket body: u32 count | (count + 1) × u32 offsets | records
  record     : u8 keyLen | key | u16 wordCount | wordCount × (u8 len, word, u32 weight)

Three tables:

  full    the pinyin a word spells run together ("nihao"), its likeliest words
  abbrev  简拼 initials ("nh")
  prefix  the first one to three letters of a pinyin ("n", "ni", "nih"): what a half-typed
          syllable may yet become, so the keyboard never has to scan keys for it

The keyboard decodes one entry on demand, so a 400k-word dictionary costs a few
mapped pages instead of tens of megabytes of Swift strings.

Run: python build-wanxiang-dictionary.py <dict dir> <out file>
"""

import os
import struct
import sys
import unicodedata
from collections import defaultdict

# Only these are worth shipping: longer entries are rare names that crowd the
# candidate list without ever being typed.
MAX_WORD_LEN = 6
# Per-key words kept, the likeliest first. A syllable typed whole fills a page of the
# candidate bar with its characters and still leaves room for the phrases they start.
WORDS_PER_KEY = 24
# How many entries survive the weight cut (~1.7M lines in the source).
MAX_ENTRIES = 420_000
# 简拼 is only built for words short enough to be worth abbreviating.
MAX_ABBREV_SYLLABLES = 5
MAX_ABBREV_WORDS = 6
# A half-typed syllable is guessed from its first letters, and holds a page of words.
MAX_PREFIX_LENGTH = 3
WORDS_PER_PREFIX = 12
# The likeliest words of each key feed the prefix table: enough to rank a syllable.
PREFIX_SOURCE_WORDS = 2


def fold(syllable):
    """ā -> a, ǚ -> v: pinyin as the keyboard types it."""
    for accented, plain in (("ü", "v"), ("ǖ", "v"), ("ǘ", "v"), ("ǚ", "v"), ("ǜ", "v"),
                            ("ń", "n"), ("ň", "n"), ("ǹ", "n"), ("ḿ", "m")):
        syllable = syllable.replace(accented, plain)
    decomposed = unicodedata.normalize("NFD", syllable)
    stripped = "".join(c for c in decomposed if not unicodedata.combining(c))
    return stripped.lower()


def read_dictionary(path):
    """Yields (word, [syllables], weight)."""
    with open(path, encoding="utf-8") as handle:
        in_body = False
        for line in handle:
            line = line.rstrip("\n")
            if not in_body:
                if line.strip() == "...":
                    in_body = True
                continue
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            word = parts[0].strip()
            syllables = [fold(s) for s in parts[1].split()]
            if not word or not syllables or any(not s or not s.isalpha() for s in syllables):
                continue
            try:
                weight = int(parts[2]) if len(parts) > 2 and parts[2].strip() else 1
            except ValueError:
                weight = 1
            yield word, syllables, max(weight, 1)


def bucket_for(key):
    if key and "a" <= key[0] <= "z":
        return ord(key[0]) - ord("a")
    return -1


def encode_bucket(records):
    """records: [(key, [(word, weight)])] sorted by key."""
    offsets = []
    body = bytearray()
    head_size = 4 + (len(records) + 1) * 4
    for key, words in records:
        offsets.append(head_size + len(body))
        raw = key.encode("ascii")
        body += struct.pack("<B", len(raw)) + raw
        body += struct.pack("<H", len(words))
        for word, weight in words:
            encoded = word.encode("utf-8")
            body += struct.pack("<B", len(encoded)) + encoded
            body += struct.pack("<I", weight)
    offsets.append(head_size + len(body))
    return struct.pack("<I", len(records)) + b"".join(struct.pack("<I", o) for o in offsets) + bytes(body)


def encode_table(entries, per_key):
    """entries: {(key): [(word, weight)]} -> 26 bucket blobs."""
    buckets = defaultdict(list)
    for key, words in entries.items():
        index = bucket_for(key)
        if index >= 0:
            buckets[index].append((key, words[:per_key]))
    return [encode_bucket(sorted(buckets.get(index, []))) for index in range(26)]


def build_prefixes(full):
    """What a half-typed syllable may yet become, per one-to-three letter prefix."""
    gathered = defaultdict(list)
    for key, words in full.items():
        for size in range(1, min(MAX_PREFIX_LENGTH, len(key)) + 1):
            gathered[key[:size]].extend(words[:PREFIX_SOURCE_WORDS])
    prefixes = {}
    for prefix, words in gathered.items():
        best = {}
        for word, weight in words:
            if best.get(word, 0) < weight:
                best[word] = weight
        prefixes[prefix] = sorted(best.items(), key=lambda item: item[1], reverse=True)[:WORDS_PER_PREFIX]
    return prefixes


def main():
    source, output = sys.argv[1], sys.argv[2]

    best = {}
    abbrevs = {}
    for name in ("zi", "jichu", "duoyin", "diming", "mingren", "yiren"):
        path = os.path.join(source, name + ".yaml")
        if not os.path.exists(path):
            print(f"skip {name}: no {path}")
            continue
        lines = 0
        for word, syllables, weight in read_dictionary(path):
            lines += 1
            if len(word) > MAX_WORD_LEN:
                continue
            key = "".join(syllables)
            if len(key) > 24:
                continue
            slot = (word, key)
            if best.get(slot, 0) < weight:
                best[slot] = weight
            if 2 <= len(syllables) <= MAX_ABBREV_SYLLABLES:
                initials = "".join(s[0] for s in syllables)
                slot = (word, initials)
                if abbrevs.get(slot, 0) < weight:
                    abbrevs[slot] = weight
        print(f"{name}: {lines} lines")
    sys.stdout.flush()

    entries = sorted(best.items(), key=lambda item: item[1], reverse=True)[:MAX_ENTRIES]
    print(f"kept {len(entries)} of {len(best)} full entries")
    sys.stdout.flush()

    full = defaultdict(list)
    total_weight = 0
    for (word, key), weight in entries:
        full[key].append((word, weight))
        total_weight += weight
    full = {k: sorted(v, key=lambda w: w[1], reverse=True)[:WORDS_PER_KEY] for k, v in full.items()}

    kept_words = {word for words in full.values() for word, _ in words}
    abbrev = defaultdict(list)
    for (word, key), weight in abbrevs.items():
        if word in kept_words:
            abbrev[key].append((word, weight))
    abbrev = {k: sorted(v, key=lambda w: w[1], reverse=True)[:MAX_ABBREV_WORDS] for k, v in abbrev.items()}

    prefixes = build_prefixes(full)
    print(f"{len(full)} full keys, {len(abbrev)} abbrev keys, {len(prefixes)} prefixes, "
          f"total weight {total_weight}")
    sys.stdout.flush()

    full_blobs = encode_table(full, WORDS_PER_KEY)
    abbrev_blobs = encode_table(abbrev, MAX_ABBREV_WORDS)
    prefix_blobs = encode_table(prefixes, WORDS_PER_PREFIX)

    header_size = 4 + 2 + 4 * 4
    table_size = 26 * 8
    full_table_at = header_size
    full_blob_at = full_table_at + table_size
    abbrev_table_at = full_blob_at + sum(len(b) for b in full_blobs)
    abbrev_blob_at = abbrev_table_at + table_size
    prefix_table_at = abbrev_blob_at + sum(len(b) for b in abbrev_blobs)
    prefix_blob_at = prefix_table_at + table_size

    with open(output, "wb") as handle:
        handle.write(b"HXWX")
        handle.write(struct.pack("<H", 2))
        handle.write(struct.pack("<IIII", full_table_at, abbrev_table_at, total_weight, prefix_table_at))
        offset = full_blob_at
        for blob in full_blobs:
            handle.write(struct.pack("<II", offset, len(blob)))
            offset += len(blob)
        for blob in full_blobs:
            handle.write(blob)
        offset = abbrev_blob_at
        for blob in abbrev_blobs:
            handle.write(struct.pack("<II", offset, len(blob)))
            offset += len(blob)
        for blob in abbrev_blobs:
            handle.write(blob)
        offset = prefix_blob_at
        for blob in prefix_blobs:
            handle.write(struct.pack("<II", offset, len(blob)))
            offset += len(blob)
        for blob in prefix_blobs:
            handle.write(blob)

    print(f"wrote {output} ({os.path.getsize(output)} bytes)")


if __name__ == "__main__":
    main()
