import Foundation

nonisolated enum KeyboardDictationState: String, Codable, Sendable {
    case offline
    case ready
    case starting
    case recording
    case transcribing
    case failed
}

nonisolated enum WarmSessionDuration: String, Codable, CaseIterable, Sendable {
    case off
    case fiveMinutes
    case fifteenMinutes
    case oneHour

    var seconds: TimeInterval? {
        switch self {
        case .off: nil
        case .fiveMinutes: 5 * 60
        case .fifteenMinutes: 15 * 60
        case .oneHour: 60 * 60
        }
    }

    var shortLabel: String {
        switch self {
        case .off: String(localized: "Off")
        case .fiveMinutes: String(localized: "5m")
        case .fifteenMinutes: String(localized: "15m")
        case .oneHour: String(localized: "1h")
        }
    }

    var title: String {
        switch self {
        case .off: String(localized: "One shot")
        case .fiveMinutes: String(localized: "5 minutes")
        case .fifteenMinutes: String(localized: "15 minutes")
        case .oneHour: String(localized: "1 hour")
        }
    }
}

nonisolated enum KeyboardCommandKind: String, Codable, Sendable {
    case start
    case stop
    case cancel
}

nonisolated struct KeyboardCommand: Codable, Equatable, Sendable {
    let id: String
    let kind: KeyboardCommandKind
    let jobID: String
    let style: DictationStyle
    let sentAt: TimeInterval

    init(
        id: String = UUID().uuidString,
        kind: KeyboardCommandKind,
        jobID: String,
        style: DictationStyle = .polished,
        sentAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.kind = kind
        self.jobID = jobID
        self.style = style
        self.sentAt = sentAt
    }
}

nonisolated enum KeyboardLaunchRequest: Equatable, Sendable {
    /// Any cold-start recording handoff older than 10 seconds warms the session instead of surprise-recording.
    static let handoffWindow: TimeInterval = 10.0

    /// Opens Hex's keyboard setup screen without starting a session.
    case setup
    /// Opens Settings › Dictation, where Translate what I say downloads its languages: the
    /// keyboard's note after a dictation went in as spoken.
    case translationSettings
    /// Jumps through Hex to iOS Settings › Apps › Hex so Paste from Other Apps can be set to
    /// Allow without hunting through Settings.
    case pasteSettings
    /// Opens Hex at Home: the Hex key menu's Open Hex.
    case home
    case startSession(requestedAt: TimeInterval?)
    case startRecording(
        jobID: String,
        requestedAt: TimeInterval?,
        style: DictationStyle?
    )

    init?(url: URL) {
        guard url.scheme == "hex-dictation", url.host == "keyboard" else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []

        func value(_ name: String) -> String? {
            guard let v = query.first(where: { $0.name == name })?.value, !v.isEmpty else {
                return nil
            }
            return v
        }

        let requestedAt = value("ts").flatMap(TimeInterval.init)
        let style = value("style").flatMap(DictationStyle.init(rawValue:))

        switch url.path {
        case "/setup":
            self = .setup
        case "/translation":
            self = .translationSettings
        case "/paste-settings":
            self = .pasteSettings
        case "/home":
            self = .home
        case "/start":
            self = .startSession(requestedAt: requestedAt)
        case "/record":
            guard let jobID = value("job") else { return nil }
            self = .startRecording(
                jobID: jobID,
                requestedAt: requestedAt,
                style: style
            )
        default:
            return nil
        }
    }

    /// Opens a page of Hex, starting no session.
    var opensPage: Bool {
        switch self {
        case .setup, .translationSettings, .pasteSettings, .home: true
        case .startSession, .startRecording: false
        }
    }

    var requestedAt: TimeInterval? {
        switch self {
        case .setup, .translationSettings, .pasteSettings, .home:
            nil
        case .startSession(let ts), .startRecording(_, let ts, _):
            ts
        }
    }

    func isHandoffExpired(at now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard let requestedAt else { return false }
        return now - requestedAt > Self.handoffWindow
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "hex-dictation"
        components.host = "keyboard"

        var items: [URLQueryItem] = []
        switch self {
        case .setup:
            components.path = "/setup"

        case .translationSettings:
            components.path = "/translation"

        case .pasteSettings:
            components.path = "/paste-settings"

        case .home:
            components.path = "/home"

        case .startSession(let requestedAt):
            components.path = "/start"
            if let requestedAt {
                items.append(URLQueryItem(name: "ts", value: String(format: "%.3f", requestedAt)))
            }

        case .startRecording(let jobID, let requestedAt, let style):
            components.path = "/record"
            items.append(URLQueryItem(name: "job", value: jobID))
            if let requestedAt {
                items.append(URLQueryItem(name: "ts", value: String(format: "%.3f", requestedAt)))
            }
            if let style {
                items.append(URLQueryItem(name: "style", value: style.rawValue))
            }
        }

        if !items.isEmpty {
            components.queryItems = items
        }
        return components.url!
    }
}

nonisolated struct KeyboardSnapshot: Codable, Equatable, Sendable {
    let state: KeyboardDictationState
    let heartbeat: TimeInterval
    let expiresAt: TimeInterval
    let recordingStartedAt: TimeInterval?
    let audioLevel: Float
    let loudnessDB: Float?
    let jobID: String?
    let resultID: String?
    let resultExpiresAt: TimeInterval?
    let transcript: String?
    let message: String?
    /// The raw transcript behind `transcript`, before cleanup and formatting, sent only while
    /// Learn how I type is on so the keyboard can tell misheard words from formatting.
    /// Nil when it can't be learned from (translated) or the experiment is off.
    let heard: String?
    /// Record typing logs: what each step of the dictation made of it, sent only while
    /// that experiment is on.
    let stages: DictationStages?
    /// Why `transcript` went in as spoken while Translate what I say was on: the keyboard
    /// says so as it inserts it.
    let translationFailure: TranslationFailure?
    /// When `message` was written (wall clock). The keyboard says it only for
    /// `messageShownFor` after that; nil (an earlier build's) reads as long past.
    let messageAt: TimeInterval?

    init(
        state: KeyboardDictationState,
        heartbeat: TimeInterval,
        expiresAt: TimeInterval,
        recordingStartedAt: TimeInterval? = nil,
        audioLevel: Float = 0,
        loudnessDB: Float? = nil,
        jobID: String? = nil,
        resultID: String? = nil,
        resultExpiresAt: TimeInterval? = nil,
        transcript: String? = nil,
        message: String? = nil,
        heard: String? = nil,
        stages: DictationStages? = nil,
        translationFailure: TranslationFailure? = nil,
        messageAt: TimeInterval? = nil
    ) {
        self.state = state
        self.heartbeat = heartbeat
        self.expiresAt = expiresAt
        self.recordingStartedAt = recordingStartedAt
        self.audioLevel = audioLevel
        self.loudnessDB = loudnessDB
        self.jobID = jobID
        self.resultID = resultID
        self.resultExpiresAt = resultExpiresAt
        self.transcript = transcript
        self.message = message
        self.heard = heard
        self.stages = stages
        self.translationFailure = translationFailure
        self.messageAt = messageAt
    }

    var effectiveLoudnessDB: Float {
        loudnessDB ?? DotScopeSimulation.loudness(fromNormalized: audioLevel)
    }

    static let offline = KeyboardSnapshot(
        state: .offline,
        heartbeat: 0,
        expiresAt: 0
    )

    var isAvailable: Bool {
        isAvailable(at: Date().timeIntervalSince1970)
    }

    /// True while the background warm session or an active capture/transcription heartbeat is live.
    func isAvailable(at now: TimeInterval) -> Bool {
        let heartbeatFresh = now - heartbeat < 3.0 && heartbeat > 0
        guard heartbeatFresh else { return false }
        if state == .starting || state == .recording || state == .transcribing {
            return true
        }
        return expiresAt > now
    }

    /// Accepted jobs keep their completed transcript deliverable even after a one-shot or expiring session closes.
    func hasDeliverableResult(at now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard let resultID, !resultID.isEmpty,
              let transcript, !transcript.isEmpty else {
            return false
        }
        if let resultExpiresAt {
            return resultExpiresAt > now
        }
        return true
    }

    func recordingElapsed(at now: TimeInterval = Date().timeIntervalSince1970) -> TimeInterval {
        guard state == .recording, let recordingStartedAt else { return 0 }
        return max(0, now - recordingStartedAt)
    }

    /// Hex heartbeats a keyboard's recording or transcription at least every 0.6 s
    /// (`DictationController`'s keyboard loop). One whose heartbeat is older than this has no
    /// one working on it: Hex ended, crashed or was suspended mid-job.
    static let orphanedJobTimeout: TimeInterval = 6
    /// How long a finished dictation the keyboard didn't insert by itself stays on offer as
    /// Paste dictation. Inserting it, or a newer one, ends the offer.
    static let resultOfferWindow: TimeInterval = 10 * 60

    /// A recording or transcription Hex stopped heartbeating for. Nothing will finish it, and
    /// a new keyboard process reads it the same way: the heartbeat is wall-clock time.
    func isOrphanedJob(at now: TimeInterval) -> Bool {
        guard state == .starting || state == .recording || state == .transcribing else { return false }
        return heartbeat <= 0 || now - heartbeat > Self.orphanedJobTimeout
    }

    /// The snapshot as the keyboard acts on it: an orphaned job reads as offline, so it can't
    /// hold the keyboard in recording or transcribing. A result it carries still arrives.
    func droppingOrphanedJob(at now: TimeInterval) -> KeyboardSnapshot {
        guard isOrphanedJob(at: now) else { return self }
        return KeyboardSnapshot(
            state: .offline,
            heartbeat: heartbeat,
            expiresAt: expiresAt,
            resultID: resultID,
            resultExpiresAt: resultExpiresAt,
            transcript: transcript,
            message: message,
            heard: heard,
            stages: stages,
            translationFailure: translationFailure,
            messageAt: messageAt
        )
    }

    /// How long the keyboard says why Hex's last dictation failed ("Another app is using the
    /// microphone. Try again."), a little longer than its own failures show.
    static let messageShownFor: TimeInterval = 8

    /// A message from more than `messageShownFor` ago, or with no time. Hex writes the
    /// snapshot only while it runs, so a failure stayed in the App Group after Hex was
    /// suspended: every keyboard after showed it, and the full keyboard's Hex key sent its
    /// dictations to a Hex still marked failed, which ignored them, though dictation itself
    /// worked (TestFlight: "showing for me all the time although it's working fine").
    func hasStaleMessage(at now: TimeInterval) -> Bool {
        guard message != nil || state == .failed else { return false }
        guard let messageAt else { return true }
        return now - messageAt > Self.messageShownFor
    }

    /// The snapshot as the keyboard shows it: a stale failure reads as offline and a stale
    /// message is dropped. Whether a warm session is up, and any result, stay as they are.
    func droppingStaleMessage(at now: TimeInterval) -> KeyboardSnapshot {
        guard hasStaleMessage(at: now) else { return self }
        return KeyboardSnapshot(
            state: state == .failed ? .offline : state,
            heartbeat: heartbeat,
            expiresAt: expiresAt,
            recordingStartedAt: recordingStartedAt,
            audioLevel: audioLevel,
            loudnessDB: loudnessDB,
            jobID: jobID,
            resultID: resultID,
            resultExpiresAt: resultExpiresAt,
            transcript: transcript,
            heard: heard,
            stages: stages,
            translationFailure: translationFailure
        )
    }

    /// A finished dictation still on offer as Paste dictation: past its time to insert by
    /// itself (`hasDeliverableResult`), within `resultOfferWindow` of it.
    func hasOfferableResult(at now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard let resultID, !resultID.isEmpty, let transcript, !transcript.isEmpty else { return false }
        guard let resultExpiresAt else { return true }
        return now < resultExpiresAt + Self.resultOfferWindow
    }
}

/// An in-keyboard dictation that finished after the keyboard hid (dismissed, or another app
/// came forward mid-dictation). It's kept in the App Group, so the next keyboard, in this
/// process or a new one, inserts it into the field it was said for while it's fresh, and
/// offers it as Paste dictation anywhere else or later.
nonisolated struct KeyboardHeldDictation: Codable, Equatable, Sendable {
    let id: String
    let text: String
    /// Learn how I type's raw transcript, as `KeyboardSnapshot.heard`.
    let heard: String?
    /// The field it was started in (`UITextDocumentProxy.documentIdentifier`), when UIKit named it.
    let document: UUID?
    let finishedAt: TimeInterval
    /// Where its recording stopped when the keyboard closed during it (`KeyboardInterruptedRecording`).
    var stoppedAfter: TimeInterval? = nil

    /// How long after it finished it still goes straight into its own field.
    static let insertWindow: TimeInterval = 30

    enum Delivery: Equatable {
        case insert
        case offer
        case expired
    }

    /// `document` is the field the keyboard is in now. A field either side couldn't name
    /// counts as the same one, as Hex's own results go into whichever field is open.
    func delivery(in document: UUID?, at now: TimeInterval) -> Delivery {
        let age = now - finishedAt
        guard age < KeyboardSnapshot.resultOfferWindow else { return .expired }
        let sameField = self.document == nil || document == nil || self.document == document
        return sameField && age < Self.insertWindow ? .insert : .offer
    }
}

/// When an in-keyboard dictation has stopped making progress, so the keyboard resets to idle
/// instead of showing it forever: its capture went quiet (WebKit's page ended or lost the
/// microphone without saying so), or its transcription never returned.
nonisolated enum KeyboardJobWatchdog {
    enum Stage {
        case recording
        case transcribing
    }

    /// The capture page sends audio about twelve times a second once it starts, and starting
    /// (web view, page, microphone) takes a second or two.
    static let captureSilence: TimeInterval = 6
    /// Apple Speech takes seconds for a long dictation; this is far past any of them.
    static let transcription: TimeInterval = 120
    /// How long a capture the page says another sound interrupted may wait to come back. A
    /// notification's tone is a second or two and Siri reading one out a few more, and the page
    /// then needs up to a second to resume and open the microphone again; a call or an alarm
    /// outlasts this, and the dictation finishes with what was said, as it always did.
    static let captureInterruption: TimeInterval = 15

    /// `lastProgress`: the stage's start, or the capture's last audio. `interruptedSince`: when
    /// the page said its capture was interrupted, nil while it isn't; that wait is never quiet.
    static func isStalled(
        _ stage: Stage,
        lastProgress: TimeInterval,
        interruptedSince: TimeInterval? = nil,
        now: TimeInterval
    ) -> Bool {
        if stage == .recording, let interruptedSince { return now - interruptedSince > captureInterruption }
        return now - lastProgress > (stage == .recording ? captureSilence : transcription)
    }
}

/// What a keyboard saw of Full Access, written from inside the keyboard: iOS tells only the
/// keyboard. `launchedAt` is when that keyboard process started. iOS can keep a keyboard
/// process running, so one started earlier may still say what it saw then.
nonisolated struct KeyboardFullAccessReport: Codable, Equatable, Sendable {
    var isOn: Bool
    var at: TimeInterval
    var launchedAt: TimeInterval
}

/// Whether Hex's keyboard is on screen, from what it writes to the App Group: shown since its
/// view last appeared (after its first frame) and not hidden since, with a sign of life less
/// than `heartbeatWindow` old (that appearance, or the Full Access report it repeats every 5 s
/// while shown), so a keyboard process that ended without hiding doesn't count. Another
/// keyboard, or iOS's dictation, takes Hex's keyboard off screen.
nonisolated enum KeyboardPresence {
    static let heartbeatWindow: TimeInterval = 7

    static func isShown(shownAt: TimeInterval?, hiddenAt: TimeInterval?, heartbeat: TimeInterval?, now: TimeInterval) -> Bool {
        guard let shownAt else { return false }
        if let hiddenAt, hiddenAt >= shownAt { return false }
        return now - max(shownAt, heartbeat ?? 0) < heartbeatWindow
    }
}

/// Full Access as Hex can know it: on once a keyboard ran with it, off only when a keyboard
/// said so since Hex last came to the foreground, and unconfirmed otherwise.
nonisolated enum KeyboardFullAccess: Equatable, Sendable {
    case on
    case off
    case unconfirmed

    /// `activeSince` is when Hex last came to the foreground. Full Access changes only in
    /// Settings, outside Hex, so a keyboard's "off" from before then may predate a grant.
    /// An "off" counts over an "on" only when it is newer and from the same or a later
    /// keyboard process: an older process may still say what it saw before the grant.
    static func resolve(
        on: KeyboardFullAccessReport?,
        off: KeyboardFullAccessReport?,
        activeSince: TimeInterval
    ) -> KeyboardFullAccess {
        if let off, on.map({ off.at > $0.at && off.launchedAt >= $0.launchedAt }) ?? true {
            return off.at >= activeSince ? .off : .unconfirmed
        }
        return on == nil ? .unconfirmed : .on
    }
}

@MainActor
struct KeyboardBridge {
    nonisolated static let appGroup = "group.anomaly.hex.mobile"

    /// Whether this install really has the App Group. Not the same as asking
    /// `UserDefaults(suiteName:)` for nil: with the entitlement gone — a free Apple ID's build,
    /// or anything a sideloading tool re-signed (they strip App Groups, which a free
    /// certificate cannot carry) — iOS still hands back a defaults object. It is a private,
    /// empty domain per process, so the app and the keyboard each read nothing of the other's
    /// and every setting silently does nothing.
    ///
    /// The container is the surest sign, but a re-sign that keeps the entitlement can leave it
    /// uncreated, and then only cfprefsd still shares the suite. So the app stamps a probe into
    /// it on launch (`writeAppGroupProbe`): a keyboard that reads the stamp back is sharing the
    /// domain, container or no container, and settings sync again.
    nonisolated static let appGroupProbe = "settings.appGroupProbe"

    /// The App Groups this install's signature actually carries, the one Hex asks for first.
    /// A sideloading tool re-signs with its own team's group — same entitlement, different
    /// identifier (`group.<team>.hex.mobile`) — and every lookup by the requested name then
    /// fails, which reads as "no App Group" and leaves the app and the keyboard each writing
    /// settings the other never sees. The provisioning profile in the bundle names the real
    /// ones, so the identifier is resolved rather than assumed.
    nonisolated static let candidateGroups: [String] = {
        var groups = [appGroup]
        for group in provisionedGroups where !groups.contains(group) {
            groups.append(group)
        }
        return groups
    }()

    /// The group whose container exists, found once: the file system does not change under it.
    nonisolated static let containerGroup: String? = candidateGroups.first {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
    }

    /// The group this install can really share through: a container that exists, or — where a
    /// re-sign kept the entitlement and never made the container — a suite that carries the
    /// other process's probe. The probe is read every time: it arrives while the keyboard runs.
    nonisolated static var resolvedAppGroup: String? {
        if let containerGroup { return containerGroup }
        for group in candidateGroups
        where UserDefaults(suiteName: group)?.string(forKey: appGroupProbe) != nil {
            return group
        }
        return nil
    }

    /// Whether this install really has the App Group. Not the same as asking
    /// `UserDefaults(suiteName:)` for nil: with the entitlement gone — a free Apple ID's build,
    /// or anything a sideloading tool re-signed (they strip App Groups, which a free
    /// certificate cannot carry) — iOS still hands back a defaults object. It is a private,
    /// empty domain per process, so the app and the keyboard each read nothing of the other's
    /// and every setting silently does nothing.
    nonisolated static var appGroupAvailable: Bool {
        resolvedAppGroup != nil
    }

    /// Writes the stamp the other process looks for, into every group this signature carries:
    /// a stripped signature writes into a domain no one else can see, which is exactly the
    /// signal that no group is shared. The keyboard writes it too, so the app can tell a
    /// keyboard's report apart from its own.
    nonisolated static func writeAppGroupProbe() {
        let stamp = Bundle.main.bundleIdentifier ?? "hex"
        for group in candidateGroups {
            UserDefaults(suiteName: group)?.set(stamp, forKey: appGroupProbe)
        }
    }

    /// Where settings live: the shared App Group when the install has one, else this process's
    /// own defaults. The fallback keeps a stripped-signature keyboard usable on its own — its
    /// language, its switches, its learned words — instead of falling back to English forever.
    nonisolated static var storage: UserDefaults? {
        if let group = resolvedAppGroup, let shared = UserDefaults(suiteName: group) {
            return shared
        }
        return .standard
    }

    /// `com.apple.security.application-groups` from the provisioning profile this build was
    /// signed with. A sideloaded .ipa has none until it is installed and signed, which is
    /// exactly when it matters, so an unreadable profile simply resolves to `[]`.
    nonisolated static let provisionedGroups: [String] = {
        var bundle = Bundle.main.bundleURL
        // The keyboard's profile is the app's: an .appex sits in PlugIns inside it.
        if bundle.pathExtension == "appex" {
            bundle = bundle.deletingLastPathComponent().deletingLastPathComponent()
        }
        let profileURL = bundle.appendingPathComponent("embedded.mobileprovision")
        guard let profile = try? Data(contentsOf: profileURL),
              let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.count)
        else { return [] }
        let xml = profile[start.lowerBound..<end.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil),
              let root = plist as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return [] }
        return groups
    }()

    /// Posted by the keyboard each time it reports Full Access (`recordFullAccess`).
    nonisolated static let fullAccessDarwinNotification = "anomaly.hex.mobile.keyboard.fullAccess"
    /// The keyboard's Darwin notification, forwarded on the main thread once
    /// `forwardFullAccessReports()` has run in the app.
    nonisolated static let fullAccessReported = Notification.Name("KeyboardBridge.fullAccessReported")

    private enum Key {
        static let command = "keyboard.command"
        static let modelInstalled = "model.installed"
        static let snapshot = "keyboard.snapshot"
        static let warmDuration = "settings.warmDuration"
        static let warmDurationReviewed = "settings.warmDuration.reviewedForKeyboardDictation"
        static let style = "settings.dictationStyle"
        static let microphone = "settings.microphone"
        /// Before Settings › Microphone: true allowed Bluetooth microphones (Always use iPhone
        /// microphone off). Read only while Microphone is unset.
        static let allowBluetoothMic = "settings.allowBluetoothMic"
        static let lastInsertedResultID = "keyboard.lastInsertedResultID"
        static let fullAccessSeenAt = "keyboard.fullAccessSeenAt"
        static let fullAccessOn = "keyboard.fullAccessOn"
        static let fullAccessOff = "keyboard.fullAccessOff"
        static let appMicrophoneAllowed = "app.microphoneAllowed"
        static let lastEmptyDictationAt = "keyboard.lastEmptyDictationAt"
        static let heldDictation = "keyboard.heldDictation"
        static let shownAt = "keyboard.shownAt"
        static let hiddenAt = "keyboard.hiddenAt"
    }

    private let defaults: UserDefaults?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults? = KeyboardBridge.storage) {
        self.defaults = defaults
    }

    func send(
        _ kind: KeyboardCommandKind,
        jobID: String,
        style: DictationStyle? = nil,
        sentAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        let command = KeyboardCommand(
            kind: kind,
            jobID: jobID,
            style: style ?? self.style,
            sentAt: sentAt
        )
        guard let data = try? encoder.encode(command) else { return }
        defaults?.set(data, forKey: Key.command)
    }

    func latestCommand() -> KeyboardCommand? {
        guard let data = defaults?.data(forKey: Key.command) else { return nil }
        return try? decoder.decode(KeyboardCommand.self, from: data)
    }

    var isModelInstalled: Bool {
        defaults?.bool(forKey: Key.modelInstalled) ?? false
    }

    func setModelInstalled(_ installed: Bool) {
        defaults?.set(installed, forKey: Key.modelInstalled)
    }

    /// Keep mic warm as chosen, else what this iPhone needs: Off where the keyboard dictates by
    /// itself, 15 minutes where Dictate opens Hex (`KeyboardSelfDictation`). Worked out on each
    /// read, never stored, so it follows the keyboard.
    var warmDuration: WarmSessionDuration {
        get {
            guard let raw = defaults?.string(forKey: Key.warmDuration),
                  let parsed = WarmSessionDuration(rawValue: raw) else {
                return defaultWarmDuration()
            }
            return parsed
        }
        nonmutating set {
            defaults?.set(newValue.rawValue, forKey: Key.warmDuration)
        }
    }

    func defaultWarmDuration(
        osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        now: Date = Date()
    ) -> WarmSessionDuration {
        keyboardDictatesItself(osMajorVersion: osMajorVersion, now: now) ? .off : .fifteenMinutes
    }

    /// The keyboard opened Hex for a dictation: it doesn't dictate by itself for now.
    func noteKeyboardOpenedHex(now: Date = Date()) {
        KeyboardSelfDictation(defaults: defaults).recordOpenedHex(at: now)
    }

    func keyboardDictatesItself(
        osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        now: Date = Date()
    ) -> Bool {
        KeyboardSelfDictation(defaults: defaults).dictatesItself(osMajorVersion: osMajorVersion, now: now)
    }

    /// Once, on iOS 26 or later: a stored 15 minutes, which tapping the default to warm the mic
    /// also stored, is taken for not chosen where the keyboard dictates by itself, so it reads
    /// Off. Off, 5 minutes and 1 hour stay as chosen.
    func reviewWarmDurationForKeyboardDictation(
        osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        now: Date = Date()
    ) {
        guard osMajorVersion >= KeyboardSelfDictation.firstVersion,
              defaults?.bool(forKey: Key.warmDurationReviewed) == false else { return }
        defaults?.set(true, forKey: Key.warmDurationReviewed)
        if defaults?.string(forKey: Key.warmDuration) == WarmSessionDuration.fifteenMinutes.rawValue,
           keyboardDictatesItself(osMajorVersion: osMajorVersion, now: now) {
            defaults?.removeObject(forKey: Key.warmDuration)
        }
    }

    var style: DictationStyle {
        get {
            guard let raw = defaults?.string(forKey: Key.style),
                  let parsed = DictationStyle(rawValue: raw) else {
                return .polished
            }
            return parsed
        }
        nonmutating set {
            defaults?.set(newValue.rawValue, forKey: Key.style)
        }
    }

    /// Settings › Microphone. Unset, it is Automatic, or Bluetooth for someone who turned off
    /// Always use iPhone microphone (the switch it replaced).
    var microphone: MicrophoneChoice {
        get {
            if let raw = defaults?.string(forKey: Key.microphone), let choice = MicrophoneChoice(rawValue: raw) {
                return choice
            }
            return defaults?.bool(forKey: Key.allowBluetoothMic) == true ? .bluetooth : .automatic
        }
        nonmutating set {
            defaults?.set(newValue.rawValue, forKey: Key.microphone)
        }
    }

    var lastInsertedResultID: String? {
        get {
            defaults?.string(forKey: Key.lastInsertedResultID)
        }
        nonmutating set {
            defaults?.set(newValue, forKey: Key.lastInsertedResultID)
        }
    }

    /// When the keyboard last ran with Full Access. Without Full Access the keyboard
    /// cannot write to the App Group at all, so only the keyboard sets this.
    var fullAccessSeenAt: TimeInterval? {
        get {
            let value = defaults?.double(forKey: Key.fullAccessSeenAt) ?? 0
            return value > 0 ? value : nil
        }
        nonmutating set {
            if let newValue {
                defaults?.set(newValue, forKey: Key.fullAccessSeenAt)
            } else {
                defaults?.removeObject(forKey: Key.fullAccessSeenAt)
            }
        }
    }

    /// Only the keyboard writes these, and a keyboard without Full Access may not be able to
    /// (an iPhone's App Group can refuse it). An "on" also sets `fullAccessSeenAt`, which
    /// builds before these reports read.
    func recordFullAccess(_ report: KeyboardFullAccessReport) {
        guard let data = try? encoder.encode(report) else { return }
        if report.isOn {
            defaults?.set(data, forKey: Key.fullAccessOn)
            defaults?.set(report.at, forKey: Key.fullAccessSeenAt)
        } else {
            defaults?.set(data, forKey: Key.fullAccessOff)
        }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.fullAccessDarwinNotification as CFString),
            nil,
            nil,
            true
        )
    }

    /// The last "on". A keyboard from before these reports left only `fullAccessSeenAt`:
    /// it counts as an "on" from the oldest process.
    var fullAccessOnReport: KeyboardFullAccessReport? {
        if let data = defaults?.data(forKey: Key.fullAccessOn),
           let report = try? decoder.decode(KeyboardFullAccessReport.self, from: data) {
            return report
        }
        return fullAccessSeenAt.map { KeyboardFullAccessReport(isOn: true, at: $0, launchedAt: 0) }
    }

    var fullAccessOffReport: KeyboardFullAccessReport? {
        guard let data = defaults?.data(forKey: Key.fullAccessOff) else { return nil }
        return try? decoder.decode(KeyboardFullAccessReport.self, from: data)
    }

    func fullAccess(activeSince: TimeInterval) -> KeyboardFullAccess {
        KeyboardFullAccess.resolve(on: fullAccessOnReport, off: fullAccessOffReport, activeSince: activeSince)
    }

    /// Forwards the keyboard's Darwin notification to `fullAccessReported`, once per process.
    static func forwardFullAccessReports() {
        _ = fullAccessForwarder
    }

    private static let fullAccessForwarder: Void = {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: KeyboardBridge.fullAccessReported, object: nil)
                }
            },
            fullAccessDarwinNotification as CFString,
            nil,
            .deliverImmediately
        )
    }()

    /// Whether Hex has the microphone, as the app last read it. Only the app sets this. A
    /// keyboard process keeps the permission it read when it started (iOS doesn't update it
    /// there), so a keyboard opened before Hex was allowed the microphone needs the app's word.
    var appMicrophoneAllowed: Bool {
        get {
            defaults?.bool(forKey: Key.appMicrophoneAllowed) ?? false
        }
        nonmutating set {
            guard newValue != appMicrophoneAllowed else { return }
            defaults?.set(newValue, forKey: Key.appMicrophoneAllowed)
        }
    }

    /// When the keyboard's own dictation last ended with nothing to insert (no speech, or too
    /// short). The keyboard stays quiet about it; onboarding's practice says it heard nothing.
    var lastEmptyDictationAt: TimeInterval? {
        get {
            let value = defaults?.double(forKey: Key.lastEmptyDictationAt) ?? 0
            return value > 0 ? value : nil
        }
        nonmutating set {
            if let newValue {
                defaults?.set(newValue, forKey: Key.lastEmptyDictationAt)
            } else {
                defaults?.removeObject(forKey: Key.lastEmptyDictationAt)
            }
        }
    }

    /// Only the keyboard writes it: a dictation it finished after it hid, until it's
    /// inserted, pasted from the strip, or expired (`KeyboardHeldDictation`).
    var heldDictation: KeyboardHeldDictation? {
        get {
            guard let data = defaults?.data(forKey: Key.heldDictation) else { return nil }
            return try? decoder.decode(KeyboardHeldDictation.self, from: data)
        }
        nonmutating set {
            if let newValue, let data = try? encoder.encode(newValue) {
                defaults?.set(data, forKey: Key.heldDictation)
            } else {
                defaults?.removeObject(forKey: Key.heldDictation)
            }
        }
    }

    /// Only the keyboard writes these: when its view last appeared and last went away
    /// (`KeyboardPresence`).
    func recordKeyboardShown(at time: TimeInterval) {
        defaults?.set(time, forKey: Key.shownAt)
    }

    func recordKeyboardHidden(at time: TimeInterval) {
        defaults?.set(time, forKey: Key.hiddenAt)
    }

    /// Hex's keyboard is on screen now (`KeyboardPresence`).
    func isKeyboardShown(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        func time(_ key: String) -> TimeInterval? {
            let value = defaults?.double(forKey: key) ?? 0
            return value > 0 ? value : nil
        }
        return KeyboardPresence.isShown(
            shownAt: time(Key.shownAt),
            hiddenAt: time(Key.hiddenAt),
            heartbeat: fullAccessOnReport?.at,
            now: now
        )
    }

    func publish(_ snapshot: KeyboardSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults?.set(data, forKey: Key.snapshot)
    }

    func snapshot() -> KeyboardSnapshot {
        guard let data = defaults?.data(forKey: Key.snapshot) else { return .offline }
        return (try? decoder.decode(KeyboardSnapshot.self, from: data)) ?? .offline
    }
}
