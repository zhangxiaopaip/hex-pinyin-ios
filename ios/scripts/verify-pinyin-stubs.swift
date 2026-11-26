import Foundation

/// Just enough of the keyboard for `PinyinDictionary` to compile on its own, so the check
/// before a build reads the shipped dictionary through the same code the keyboard runs. The
/// real `KeyboardBridge` lives in `HEXShared`, and `UserWords` beside the dictionary; here
/// the App Group is out of reach, which is what a stripped signature's keyboard also sees.

enum KeyboardBridge {
    nonisolated static var storage: UserDefaults? { nil }
}

nonisolated final class UserWords: @unchecked Sendable {
    static let shared = UserWords()

    func boost(for word: String) -> Double { 0 }

    func learn(_ word: String) {}
}
