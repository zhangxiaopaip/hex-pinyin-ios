import Foundation

/// Just enough of `HEXShared` for the Chinese rules to compile on their own, so the check before
/// a build runs the same code the app does. The real `KeyboardBridge` keeps settings in the App
/// Group; here there is no group, which leaves `ChineseDictationSettings` on its defaults — on,
/// the way a fresh install has them.
enum KeyboardBridge {
    nonisolated static var storage: UserDefaults? { nil }
}

/// `DictationLanguage.swift`'s picker, reduced to the one question the formatter asks it: every
/// rule it decides is English-only, and a Chinese check needs the answer to be "no".
enum SpeechLanguagePicker {
    nonisolated static func isEnglish(_ identifier: String?) -> Bool {
        guard let identifier else { return true }
        return Locale(identifier: identifier).language.languageCode?.identifier == "en"
    }
}
