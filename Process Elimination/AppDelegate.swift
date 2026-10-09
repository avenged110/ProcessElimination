// MARK: – AppDelegate.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Entry point and application delegate for Process Elimination.app.

import Cocoa
import Combine
// MARK: – AppDelegate

// Plain AppKit entry point, as in Toggler. A SwiftUI `App` needs at least one Scene, and
// an empty WindowGroup is not free: closing its window at launch only works once, because
// SwiftUI re-creates the 0×0 window on every reopen event (launching the app again while
// it is running, e.g. from Xcode, Finder or the Dock), and Mission Control then lists
// that invisible window under "Process Elimination". With no Scene there is nothing to
// re-create.
@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, Loggable {
    nonisolated static let logTag = "[AppDelegate]"

    // MARK: - Entry point

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    // Controllers
    var statusMenuController: StatusMenuController!
    private var permCon: PermissionController!
    private var pk: ProcessKiller?
    private var aq: ApplicationQuitter?

    // Combine subscriptions. Cancellables are stored here so they live for the
    // lifetime of AppDelegate and are automatically canceled on deallocation.
    private var cancellables = Set<AnyCancellable>()

    // Cache application version and build numbers once for reuse in logs
    private let appVersionBuild: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))" }()

    // MARK: - Application lifecycle
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lock to accessory mode for the lifetime of the process. The activation policy
        // never changes again — the settings window opens without a Dock icon or
        // menu bar, matching the EthernetStatus pattern.
        NSApp.setActivationPolicy(.accessory)

        // Order matters: prepareLogDirectory() reads Preferences.loggingEnabled, so the
        // registered defaults must be in place first, and the shared logger must be
        // bootstrapped before the first log line.
        Preferences.ensureDefaultsRegistered()
        Logger.bootstrap(.init(fileName: "ProcessElimination.log",
                               destination: .containerLibraryLogs,
                               isEnabled: { Preferences.loggingEnabled }))
        Logger.prepareLogDirectory()
        log("Process Elimination application \(appVersionBuild) launched.")

        // Initialize external controllers and install the status item.
        permCon = PermissionController()
        statusMenuController = StatusMenuController(permCon: permCon)
        statusMenuController.install()

        // Subscribe to preference changes via Combine. Preferences.preferencesChanged
        // is a PassthroughSubject<String, Never> that emits the changed key string
        // whenever a user-facing preference is written. Receiving on RunLoop.main
        // guarantees delivery on the main actor without an explicit DispatchQueue hop.
        // This replaces the former NotificationCenter selector-based observer.
        Preferences.preferencesChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] changedKey in
                self?.handlePreferencesChanged(key: changedKey)
            }
            .store(in: &cancellables)

        // Trigger seeding of application in Settings.app list for so-called
        // 'Accessibility' TCC-based permission.
        // Note: This doesn't work as of yet.
        permCon.triggerTCCSeed()

        // Start ProcessKiller according to preference
        if Preferences.killBlacklistedProcessesEnabled {
            log("PK enabled by preference at launch — initializing.")
            pk = ProcessKiller()
        } else {
            log("PK disabled by preference at launch — not starting.") }

        // Start ApplicationQuitter according to preference
        if Preferences.quitBlacklistedApplicationsEnabled {
            log("AQ enabled by preference at launch — initializing.")
            aq = ApplicationQuitter()
        } else {
            log("AQ disabled by preference at launch — not starting.") } }

    // Called by AppKit when a termination was requested (Quit from Dock, Cmd-Q, etc.)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        log("applicationShouldTerminate: Beginning controlled shutdown")
        // Tell status controller immediately that termination is starting
        statusMenuController?.markTerminating()
        // Ask the StatusMenuController to perform an immediate, synchronous teardown.
        // This removes the status item and closes any windows Process Elimination owns
        // so AppKit isn't left with UI still attached when it wants to terminate.
        statusMenuController?.prepareForTerminationSynchronously()
        // Stop ProcessKiller's timer synchronously as a final step.
        pk?.stopTimerImmediately()
        // Cancel all Combine subscriptions so no preference-change events are
        // processed during or after shutdown.
        cancellables.removeAll()
        // Log the final shutdown messages BEFORE requesting the log flush.
        // Any log() call after the flush races against it and is silently dropped, so all
        // terminal log entries are placed here instead.
        log("applicationShouldTerminate: Finished shutdown cleanup — allowing termination")
        log("Process Elimination application \(appVersionBuild) terminating.")
        // Flush any buffered log messages before allowing the process to exit.
        //
        // shutdownLoggingBlocking(), NOT shutdownLogging(): the latter is
        // 'Task.detached { await shutdownLoggingAwaiting() }' — fire-and-forget — and this
        // method returns .terminateNow on the very next line, so the process was being torn
        // down before that detached task was ever scheduled and these last lines never
        // reached disk. The blocking variant waits for the buffer to land; it runs on
        // LoggerCore's own executor rather than the main actor, so it cannot deadlock here.
        Logger.shutdownLoggingBlocking()
        // Allow termination now that everything's been cleaned up synchronously.
        return .terminateNow }

    func applicationWillTerminate(_ notification: Notification) {
        // Kept minimal — applicationShouldTerminate() already performed all
        // synchronous cleanup and flushed the log. statusMenuController was already
        // nilled inside prepareForTerminationSynchronously(); this assignment is
        // intentionally retained here as an explicit final release of the strong
        // reference held by AppDelegate, ensuring ARC frees the object promptly
        // rather than waiting for AppDelegate itself to deallocate.
        statusMenuController = nil }

    // MARK: - Preference sync
    // Single handler that routes preference-change events to the appropriate
    // controller. ProcessKiller and ApplicationQuitter do not subscribe themselves;
    // all routing is centralized here to avoid double-handling.
    // Called from the Combine sink on the main actor.
    private func handlePreferencesChanged(key changedKey: String) {
        // --- Process Killer handling ---
        let pkRelevantKeys: Set<String> = [
            Preferences.Keys.killBlacklistedProcessesEnabled,
            Preferences.Keys.processKillIntervalSeconds,
            Preferences.Keys.blacklistedProcesses ]

        if pkRelevantKeys.contains(changedKey) {
            if changedKey == Preferences.Keys.killBlacklistedProcessesEnabled {
                if Preferences.killBlacklistedProcessesEnabled {
                    if pk == nil {
                        log("ProcessKiller enabled by preference — initializing.")
                        pk = ProcessKiller() }
                    pk?.refreshFromPreferences()
                } else if let killer = pk {
                    log("ProcessKiller disabled by preference — stopping and releasing.")
                    killer.stopTimer()
                    pk = nil }
            } else {
                log("Preferences change affects ProcessKiller (key: '\(changedKey)'). Refreshing.")
                pk?.refreshFromPreferences() } }

        // --- Application Quitter handling ---
        let aqRelevantKeys: Set<String> = [
            Preferences.Keys.quitBlacklistedApplicationsEnabled,
            Preferences.Keys.blacklistedApplications,
            Preferences.Keys.aqGraceDelaySeconds ]

        if aqRelevantKeys.contains(changedKey) {
            if changedKey == Preferences.Keys.quitBlacklistedApplicationsEnabled {
                if Preferences.quitBlacklistedApplicationsEnabled {
                    if aq == nil {
                        log("Application Quitter enabled by preference — initializing.")
                        aq = ApplicationQuitter() }
                    aq?.refreshFromPreferences()
                } else if let quitter = aq {
                    // FIX (Issue 9): Explicitly cancel pending work items and unregister
                    // SWL PIDs before releasing the instance. refreshFromPreferences()
                    // performs the full teardown (cancels pendingChecks, unregisters PIDs)
                    // when the preference is disabled, ensuring no work items fire against
                    // a deallocated object. Naming the binding avoids a retain cycle.
                    log("Application Quitter disabled by preference — tearing down and releasing.")
                    quitter.refreshFromPreferences()
                    aq = nil }
            } else if changedKey == Preferences.Keys.blacklistedApplications {
                // Only the blacklist itself requires re-registering SWL/AX monitoring
                // (apps may have been added or removed). aqGraceDelaySeconds is
                // deliberately excluded from this branch: ApplicationQuitter reads that
                // value live at the moment it schedules a quit check (see
                // handleWindowDestroyedEvent), so changing it needs no registration
                // work at all. Routing it through refreshFromPreferences() previously
                // caused a full, needless AXObserver teardown/reinstall for every
                // monitored app on every grace-delay edit.
                log("Preferences change affects Application Quitter (key: '\(changedKey)'). Refreshing.")
                aq?.refreshFromPreferences() } }
        // The status menu is rebuilt from the live preferences on every open, so an
        // external change is picked up with no reconcile pass here.
    }

    // MARK: – External helper
    // Target of the "About Process Elimination" item in the temporary main menu that
    // SettingsKit installs while the Settings window is open (see
    // SettingsWindowConfiguration.aboutMenuAction in StatusMenuController). Routes through
    // this delegate so the live StatusMenuController instance handles the request safely.
    @MainActor
    @objc func showAboutPanel(_ sender: Any?) {
        statusMenuController?.showAboutPanel() }
}
