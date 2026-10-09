// MARK: – Preferences.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Centralized preferences wrapper used across Process Elimination.app, providing
// a single place to read/write UserDefaults-backed settings.

import Foundation
import AppKit
import Combine

// Codable model for blacklisted applications
// (Icons are resolved by AppIconCache in STabAQ.swift.)
struct BlacklistedApplication: Codable, Equatable {
    let bundleID: String
    let displayName: String }

struct Preferences: Loggable {
    static let logTag = "[Preferences]"
    // UserDefaults.standard is internally thread-safe for standard read/write operations
    // per Apple's documentation. Preferences accessors are called from multiple contexts
    // (the main thread, ProcessKiller's timerQueue, the logger's executor), so
    // the thread-safety of UserDefaults.standard is the actual guarantee here, not
    // actor isolation. A computed accessor (rather than a stored nonisolated(unsafe)
    // global) satisfies both Swift 6 strict concurrency and strict memory safety
    // without restricting this struct to a single actor; .standard is a cached
    // singleton, so there is no per-call cost.
    private static var defaults: UserDefaults { .standard }

    // Combine publisher that emits the changed preference key string whenever a
    // user-facing preference is written. Replaces the former NotificationCenter
    // broadcast (processEliminationPreferencesChanged). All consumers — AppDelegate,
    // SettingsTabPKController, and SettingsTabAQView — subscribe via Combine or
    // SwiftUI's .onReceive(Preferences.preferencesChanged) directly.
    //
    // PassthroughSubject is not Sendable, so this property is isolated to
    // @MainActor to satisfy Swift's strict-concurrency requirement that static
    // stored properties shared across concurrency domains be either Sendable or
    // isolated to a global actor. All send() call sites reach this publisher only
    // through sendPreferencesChanged(_:) below, which is itself @MainActor-isolated,
    // ensuring the publisher is always driven from the main actor.
    @MainActor
    static let preferencesChanged = PassthroughSubject<String, Never>()

    // Single, @MainActor-isolated gateway for sending on preferencesChanged.
    // All internal code that needs to fire the publisher calls this function
    // rather than accessing preferencesChanged directly. This keeps the
    // publisher's @MainActor isolation self-contained and lets getters,
    // setters, and setIfChanged remain nonisolated — compatible with
    // Swift 5 / Xcode 15.4, which does not support per-accessor actor attributes.
    @MainActor
    static func sendPreferencesChanged(_ key: String) {
        preferencesChanged.send(key) }

    private static let builtInBlacklistedProcesses: [String] = [
        "WallpaperVideoExtension",
        "AvatarPickerMemojiPicker",
        "AvatarPickerMemojiEditor",
        "AvatarPickerPosePicker",
        "Ventura",
        "com.apple.CloudPhotosConfiguration",
        "com.apple.accessibility.mediaaccessibilityd",
        "mapssyncd",
        "com.apple.SiriTTSService.TrialProxy" ]

    private static let builtInBlacklistedApplications: [BlacklistedApplication] = [
        BlacklistedApplication(bundleID: "com.apple.Preview", displayName: "Preview") ]

    // Keys used for UserDefaults.
    // Internal access so that AppDelegate can reference canonical key strings
    // directly when building its routing sets for preference-change subscriptions,
    // without duplicating string literals.
    enum Keys {
        static let loggingEnabled =
            "preferences.loggingEnabled"
        static let killBlacklistedProcessesEnabled =
            "preferences.killBlacklistedProcessesEnabled"
        static let processKillIntervalSeconds =
            "preferences.processKillIntervalSeconds"
        static let blacklistedProcesses =
            "preferences.blacklistedProcesses"
        static let quitBlacklistedApplicationsEnabled =
            "preferences.quitBlacklistedApplicationsEnabled"
        static let blacklistedApplications =
            "preferences.blacklistedApplications"
        static let aqGraceDelaySeconds =
            "preferences.aqGraceDelaySeconds"
        static let aqWasForced =
            "preferences.aqWasForced"
        static let aqPreForcedState =
            "preferences.aqPreForcedState" }

    // Register sane defaults once. Guarantees behavior for the rest
    // of the application without callers needing special 'nil' checks.
    private static let _registeredDefaults: Void = {
        let appListData: Data
        do {
            appListData = try JSONEncoder().encode(builtInBlacklistedApplications)
        } catch {
            FileHandle.standardError.write(Data("[Preferences] ERROR: Failed to encode builtInBlacklistedApplications at launch: \(error.localizedDescription)\n".utf8))
            appListData = Data()
        }
        let defaultsToRegister: [String: Any] = [
            Keys.loggingEnabled: false,
            Keys.killBlacklistedProcessesEnabled: false,
            Keys.processKillIntervalSeconds: 5,
            Keys.blacklistedProcesses: builtInBlacklistedProcesses,
            Keys.quitBlacklistedApplicationsEnabled: false,
            Keys.blacklistedApplications: appListData,
            Keys.aqGraceDelaySeconds: 3 ]
        defaults.register(defaults: defaultsToRegister) }()

    // Ensure the registration has run (force the static initializer).
    // Made non-private so callers (AppDelegate) can explicitly ensure
    // registration early during app launch, if desired.
    static func ensureDefaultsRegistered() { _ = _registeredDefaults }

    // MARK: - Toggles
    //
    // Isolation model for all preference properties:
    //
    //   • All properties (getters and setters) are nonisolated — UserDefaults
    //     reads and writes are thread-safe and may be called from any context.
    //
    //   • Notifying observers (preferencesChanged.send) must happen on the main
    //     actor. Setters and repair-path getters do this by calling
    //     sendPreferencesChanged(_:) via Task { @MainActor in }, which is the
    //     correct Swift 5 / Xcode 15.4 pattern. Per-accessor actor attributes
    //     (e.g. "@MainActor set") are a Swift 6 feature and are not used here.
    //
    //   • setIfChanged() is also nonisolated; it dispatches the notification hop
    //     to the main actor via Task { @MainActor in sendPreferencesChanged }.

    static var killBlacklistedProcessesEnabled: Bool {
        get { defaults.bool(forKey: Keys.killBlacklistedProcessesEnabled) }
        set {
            ensureDefaultsRegistered()
            setIfChanged(newValue, forKey: Keys.killBlacklistedProcessesEnabled,
                logMessage: "killBlacklistedProcessesEnabled set to \(newValue)") } }

    static var quitBlacklistedApplicationsEnabled: Bool {
        get { defaults.bool(forKey: Keys.quitBlacklistedApplicationsEnabled) }
        set {
            ensureDefaultsRegistered()
            setIfChanged(newValue, forKey: Keys.quitBlacklistedApplicationsEnabled,
                logMessage: "quitBlacklistedApplicationsEnabled set to \(newValue)") } }

    // Grace delay (in whole seconds) before AQ quits an app after its last window closes.
    // Bounds: 1–60 seconds. Default: 3 seconds.
    // Stored as Int; getter repairs out-of-range values written by external tools.
    static var aqGraceDelaySeconds: Int {
        get {
            ensureDefaultsRegistered()
            let v = defaults.integer(forKey: Keys.aqGraceDelaySeconds)
            // integer(forKey:) returns 0 when the key is absent; treat as unset.
            if v >= 1 && v <= 60 { return v }
            // Repair: value missing or out of range — reset to default.
            let defaultValue = 3
            defaults.set(defaultValue, forKey: Keys.aqGraceDelaySeconds)
            Task { @MainActor in
                Preferences.log("aqGraceDelaySeconds: Missing or out of range; resetting to \(defaultValue).")
                Preferences.sendPreferencesChanged(Keys.aqGraceDelaySeconds) }
            return defaultValue }
        set {
            ensureDefaultsRegistered()
            let safe = max(1, min(60, newValue))
            setIfChanged(safe, forKey: Keys.aqGraceDelaySeconds,
                logMessage: "aqGraceDelaySeconds set to \(safe)") } }

    static var loggingEnabled: Bool {
        get { defaults.bool(forKey: Keys.loggingEnabled) }
        set {
            ensureDefaultsRegistered()
            setIfChanged(newValue, forKey: Keys.loggingEnabled,
                logMessage: "loggingEnabled set to \(newValue)") } }

    // MARK: – Process killer blacklist
    // Interval in seconds between process killer runs (default: 5)
    // Bounds: 1–3600 seconds. Getter repairs out-of-range values written by
    // external tools, mirroring the aqGraceDelaySeconds pattern below.
    static var processKillIntervalSeconds: Int {
        get {
            ensureDefaultsRegistered()
            let v = defaults.integer(forKey: Keys.processKillIntervalSeconds)
            // integer(forKey:) returns 0 when the key is absent; treat as unset.
            if v >= 1 && v <= 3600 { return v }
            // Repair: value missing or out of range — reset to default.
            let defaultValue = 5
            defaults.set(defaultValue, forKey: Keys.processKillIntervalSeconds)
            Task { @MainActor in
                Preferences.log("processKillIntervalSeconds: Missing or out of range; resetting to \(defaultValue).")
                Preferences.sendPreferencesChanged(Keys.processKillIntervalSeconds) }
            return defaultValue }
        set {
            ensureDefaultsRegistered()
            let safe = max(1, min(3600, newValue))
            setIfChanged(safe, forKey: Keys.processKillIntervalSeconds,
                logMessage: "processKillIntervalSeconds set to \(safe)") } }

    // Blacklisted processes master list
    // Getter behavior:
    //  - If the key holds a [String], returns it — INCLUDING an empty one.
    //  - If absent or non-convertible, repairs and returns the built-in list.
    //
    // An empty array is a legitimate user choice (every row removed in the Process List
    // tab), not corruption. Treating it as corruption — as the previous '!arr.isEmpty'
    // test did — made the list impossible to empty: the setter persisted [], the write
    // fired preferencesChanged, the tab's subscriber re-read this getter, and the nine
    // built-in entries reappeared in the table the user had just cleared. The application
    // blacklist below never had this rule, and ProcessKiller already handles an empty
    // list explicitly, so nothing downstream depends on it being non-empty.
    static var blacklistedProcesses: [String] {
        get {
            ensureDefaultsRegistered()
            if let arr = defaults.array(forKey: Keys.blacklistedProcesses) as? [String] {
                return deduplicated(arr, by: { $0 }) }
            // Repair: persist built-in defaults, then notify on the main actor.
            let builtIn = builtInBlacklistedProcesses
            defaults.set(builtIn, forKey: Keys.blacklistedProcesses)
            Task { @MainActor in
                Preferences.log("blacklistedProcesses: Missing or invalid; writing built-in defaults.")
                Preferences.sendPreferencesChanged(Keys.blacklistedProcesses) }
            return builtIn }
        set {
            ensureDefaultsRegistered()
            let sanitized = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let unique = deduplicated(sanitized, by: { $0 })
            setIfChanged(unique, forKey: Keys.blacklistedProcesses,
                logMessage: "blacklistedProcesses updated (\(unique.count) entries)") } }

    // MARK: – Application quitter blacklist
    // Blacklisted applications master list
    // Getter behavior:
    //  - If the key exists, returns the stored array.
    //  - If absent or non-convertible, repairs and returns the built-in list.
    static var blacklistedApplications: [BlacklistedApplication] {
        get {
            ensureDefaultsRegistered()
            if let data = defaults.data(forKey: Keys.blacklistedApplications),
               let decoded = try? JSONDecoder().decode([BlacklistedApplication].self,
                    from: data) { return deduplicated(decoded, by: \.bundleID) }
            // Repair: persist built-in defaults, then notify on the main actor.
            let fallback = builtInBlacklistedApplications
            do {
                let encoded = try JSONEncoder().encode(fallback)
                defaults.set(encoded, forKey: Keys.blacklistedApplications)
            } catch {
                FileHandle.standardError.write(Data("[PREFS] ERROR: Failed to encode builtInBlacklistedApplications during repair: \(error.localizedDescription)\n".utf8))
            }
            Task { @MainActor in
                Preferences.log("blacklistedApplications: Missing/corrupt; Resetting to built-in default(s).")
                Preferences.sendPreferencesChanged(Keys.blacklistedApplications) }
            return fallback }
        set {
            ensureDefaultsRegistered()
            let newValue = deduplicated(newValue, by: \.bundleID)
            // Skip encoding if identical to what is already persisted.
            if let existingData = defaults.data(forKey: Keys.blacklistedApplications),
               let existing = try? JSONDecoder().decode([BlacklistedApplication].self,
                    from: existingData),
               existing == newValue { return }
            do {
                let encoded = try JSONEncoder().encode(newValue)
                defaults.set(encoded, forKey: Keys.blacklistedApplications)
                Task { @MainActor in
                    Preferences.sendPreferencesChanged(Keys.blacklistedApplications) }
                log("blacklistedApplications updated (\(newValue.count) entries)")
            } catch {
                log("ERROR: Failed to encode blacklistedApplications — changes not saved: \(error.localizedDescription)")
            } } }

    // MARK: – Helpers
    // Drops every entry whose key matches (case-insensitively, like the settings tabs'
    // duplicate checks) an earlier one, keeping the first and preserving order. Both
    // blacklists pass through this on read and on write, so no path — an undo, a drop, a
    // multi-selection in the open panel, or a direct write to the defaults domain — can
    // leave a duplicate in either list.
    private static func deduplicated<T>(_ items: [T], by key: (T) -> String) -> [T] {
        var seen = Set<String>()
        return items.filter { seen.insert(key($0).lowercased()).inserted } }

    static func resetProcessBlacklistToDefaults() {
        Preferences.blacklistedProcesses = Preferences.builtInBlacklistedProcesses }

    static func resetApplicationBlacklistToDefaults() {
        Preferences.blacklistedApplications = Preferences.builtInBlacklistedApplications }

    // Change Guard: Sets a value only if it actually differs, logs, and fires
    // the preferencesChanged publisher on the main actor via sendPreferencesChanged.
    // Nonisolated — safe to call from any context; the publisher hop is async.
    //
    // Type dispatch covers all preference value types actually used in this file:
    // Bool, Int, and [String]. The Data-backed blacklistedApplications preference
    // has its own equality guard in its setter and does not route through here.
    private static func setIfChanged<T: Equatable>(_ value: T, forKey key: String, logMessage: String? = nil) {
        var isSame = false

        if let v = value as? Bool { isSame = defaults.bool(forKey: key) == v
        } else if let v = value as? Int { isSame = defaults.integer(forKey: key) == v
        } else if let v = value as? Double { isSame = defaults.double(forKey: key) == v
        } else if let v = value as? String { isSame = defaults.string(forKey: key) == v
        } else if let v = value as? [String] {
            if let current = defaults.array(forKey: key) as? [String] { isSame = current == v
            } else { isSame = false }
        } else {
            let current: T? = defaults.object(forKey: key) as? T
            isSame = (current == value) }

        if isSame { return }

        defaults.set(value, forKey: key)
        if let message = logMessage, Logger.isLoggingEnabled { log(message) }
        Task { @MainActor in Preferences.sendPreferencesChanged(key) } }
}

// MARK: – Application Quitter pre-forced state
// Stores the user's AQ toggle preference before it was forcibly overridden due to
// denied TCC permissions. These two keys are internal bookkeeping values consumed
// only by PermissionController; they are written directly to UserDefaults without
// going through setIfChanged so that no spurious preferencesChanged events are
// sent for keys that no subscriber meaningfully handles.
extension Preferences {
    private static var aqPreForcedStateDict: [String: Bool]? {
        get {
            guard let raw = defaults.dictionary(forKey: Keys.aqPreForcedState) else {
                return nil }
            var out: [String: Bool] = [:]
            for (k, v) in raw {
                if let b = v as? Bool { out[k] = b }
                else if let n = v as? NSNumber { out[k] = n.boolValue } }
            return out.isEmpty ? nil : out }
        set {
            ensureDefaultsRegistered()
            if let dict = newValue {
                defaults.set(dict, forKey: Keys.aqPreForcedState)
                log("aqPreForcedState saved")
            } else {
                defaults.removeObject(forKey: Keys.aqPreForcedState) } } }

    static var aqWasForced: Bool {
        get { defaults.bool(forKey: Keys.aqWasForced) }
        set {
            ensureDefaultsRegistered()
            guard defaults.bool(forKey: Keys.aqWasForced) != newValue else { return }
            defaults.set(newValue, forKey: Keys.aqWasForced)
            log("aqWasForced set to \(newValue)") } }

    @MainActor
    static func saveAQPreForcedState() {
        let dict: [String: Bool] = [
            Keys.quitBlacklistedApplicationsEnabled: quitBlacklistedApplicationsEnabled ]
        aqPreForcedStateDict = dict
        aqWasForced = true
        log("Saved AQ pre-forced state: \(dict)") }

    @MainActor
    static func restoreAQPreForcedState() {
        // A missing saved state must still clear the flag: left set, every later call
        // would return here and a future denial would never save a fresh state.
        guard let dict = aqPreForcedStateDict else {
            aqWasForced = false
            log("No saved AQ pre-forced state to restore; clearing aqWasForced.")
            return }
        if let toggle = dict[Keys.quitBlacklistedApplicationsEnabled] {
            quitBlacklistedApplicationsEnabled = toggle }
        aqPreForcedStateDict = nil
        aqWasForced = false
        log("Restored AQ pre-forced state: \(dict)") }
}
