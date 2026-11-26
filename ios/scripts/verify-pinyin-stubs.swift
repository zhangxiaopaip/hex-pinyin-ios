import Foundation

/// Just enough of the keyboard for `PinyinDictionary` to compile on its own, so the check
/// before a build reads the shipped dictionary through the same code the keyboard runs. The
/// real `KeyboardBridge` is in `HEXShared`; here the App Group is out of reach, which is what
/// a stripped signature's keyboard also sees. `UserWords` needs no stand-in: it lives in
/// `PinyinDictionary.swift` itself, in the keyboard's own defaults.

enum KeyboardBridge {
    nonisolated static var storage: UserDefaults? { nil }
}
