// MARK: – ApplicationQuitter.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Minimal Application Quitter: AQ owns preferences and registers PIDs with SWL.
// When SWL reports known windows == 0, AQ attempts graceful quit (terminate) and
// falls back to forceTerminate.

import Foundation
import AppKit
import Synchronization

// The values that ApplicationQuitter.deinit must read.
//
// Swift prohibits accessing @MainActor-isolated stored properties in `deinit`
// because the compiler treats the deinit body as exiting actor isolation — even
// properties marked `nonisolated(unsafe)` on the actor-isolated `self` are
// rejected. What `deinit` can read is a nonisolated, Sendable `let` constant, so
// these are held in a Mutex (see `deinitContext`). Every member is Sendable
// (`SWLState` is an actor, `UUID` a value), so the compiler checks the whole
// arrangement; nothing about it rests on an unchecked conformance.
//
// The values are written on the main actor, in lockstep with the corresponding
// fields on ApplicationQuitter, and read once in `deinit`.
private struct SWLDeinitContext: Sendable {
    var state: SWLState?
    var handlerToken: UUID?
    var appearedHandlerToken: UUID?
}

@MainActor
final class ApplicationQuitter: Loggable {
    nonisolated static let logTag = "[AppQuitter]"

    // Debounce pending quit checks keyed by PID (see pendingKey(for:)).
    // Values are Tasks so they can be canceled with a single .cancel() call,
    // replacing the previous DispatchWorkItem + inner Task double-wrap.
    //
    // Each entry carries a token identifying the individual check. A finishing check must
    // remove only its OWN entry: if it was already past its cancellation points (inside
    // terminate(), say) when a fresh window-destroyed event scheduled a successor under
    // the same key, an unconditional removeValue would delete the successor's entry and
    // leave that successor running but untracked — no longer reachable by
    // handleWindowAppearedEvent, and so no longer cancellable by the user opening a new
    // window during its grace period. See clearPendingCheck(forKey:token:).
    private struct PendingCheck {
        let token: UUID
        let task: Task<Void, Never>
    }
    private var pendingChecks: [String: PendingCheck] = [:]

    // Pending checks are keyed by PID, never by bundle ID. Two processes can share a
    // bundle ID (a second copy of an application, or one relaunched while the first is
    // still shutting down); under a bundle-keyed table the second's window-destroyed
    // event would evict and cancel the first's grace period, and the first would then
    // never be quit. SWL events, registeredPIDs, and NSWorkspace notifications are all
    // per-PID already, so a per-PID key is also the one every caller can derive without a
    // lookup.
    private static func pendingKey(for pid: pid_t) -> String { "pid-\(pid)" }

    // SWL actor state + handler tokens
    private var swlState: SWLState?
    private var swlHandlerToken: UUID?
    // Token for the WindowAppearedEvent handler — used to cancel pending quit tasks
    // when a new window opens in an app that is currently inside its grace period.
    private var swlAppearedHandlerToken: UUID?

    // Holds copies of swlState, swlHandlerToken, and swlAppearedHandlerToken that
    // deinit can read without crossing the @MainActor isolation boundary. It is a
    // `let` constant, so it is nonisolated and accessible from deinit. The main
    // actor writes its properties in lockstep with the fields above.
    private let deinitContext = Mutex(SWLDeinitContext())

    // Cached reference to NSWorkspace.shared.notificationCenter, obtained once on the
    // main actor during init() and stored as a plain let constant so deinit can call
    // removeObserver without crossing the @MainActor isolation boundary that
    // NSWorkspace.shared imposes in Swift 6. NotificationCenter is Sendable, so no
    // nonisolated(unsafe) annotation is needed — a Sendable let constant is freely
    // accessible from any concurrency context, including deinit.
    private let workspaceNC: NotificationCenter

    // Bookkeeping: Exact PIDs AQ registered with SWL.
    private var registeredPIDs: Set<pid_t> = []

    // Registration attempts in flight, keyed by PID. Each is a retry loop (see
    // registerWithRetry) so that an application whose AX server is not ready at the
    // instant it launches is picked up a moment later rather than never. Tracked so
    // that a PID is only ever being registered by one loop at a time, and so the loops
    // can be canceled when the PID is unregistered or AQ shuts down. The token serves
    // the same purpose as PendingCheck.token: a canceled loop that is superseded by a
    // fresh one for the same PID must not evict its successor's entry on the way out.
    private struct RegistrationAttempt {
        let token: UUID
        let task: Task<Void, Never>
    }
    private var registrationAttempts: [pid_t: RegistrationAttempt] = [:]

    // Init-time task
    private var swlInitTask: Task<Void, Never>?

    // Ensures only one registration/unregistration run executes at a time.
    private var registrationTask: Task<Void, Never>? = nil
    private var registrationNeedsRerun: Bool = false

    // Set once refreshFromPreferences() has begun tearing this instance down. AppDelegate
    // releases its reference immediately afterwards, but tasks already in flight — the
    // init task, a registration refresh, an nsAppLaunched registration — keep the object
    // alive until they finish, and used to keep *working* too: each re-read the enabled
    // preference and, if the user had re-enabled AQ in the meantime, went on to register
    // applications under this instance's SWLState (whose handlers were about to be
    // removed) and to interfere with the wrappers the replacement instance had installed.
    // Every path that could register or unregister now checks this flag first.
    private var isShutDown = false

    init() {
        // Initialize all let constants before any other code. Swift requires every
        // stored let to be assigned before the first non-assignment statement executes.
        // NSWorkspace.shared is @MainActor-isolated; init() runs on the main actor
        // so this access is safe and correct here.
        workspaceNC = NSWorkspace.shared.notificationCenter

        log("init() — initializing; Starting SWL.")

        // Observe application launches (on NSWorkspace's NC) to register blacklisted
        // applications that start later.
        workspaceNC.addObserver(self,
            selector: #selector(nsAppLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        // Observe application termination (on NSWorkspace's NC) so AQ can clean up
        // its bookkeeping.
        workspaceNC.addObserver(self,
            selector: #selector(nsAppTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        startSWLIfNeeded() }

    deinit {
        // Remove NSWorkspace observers registered in init().
        // workspaceNC is a nonisolated(unsafe) let constant assigned in init(); it
        // is safe to access here because no concurrent mutation is possible once
        // the retain count reaches zero. Using the stored reference avoids the
        // @MainActor isolation crossing that NSWorkspace.shared.notificationCenter
        // would require in Swift 6.
        workspaceNC.removeObserver(self)
        // Deregister SWL handlers and tear down the SWLState workspace observer.
        //
        // Swift 6 prohibits a closure inside deinit from capturing 'self', even
        // implicitly through a 'let' constant stored on self, because the closure
        // could outlive the deinit frame. The fix is Task.detached with an explicit
        // capture list: [context] captures a copy of the SWLDeinitContext values (a
        // Sendable struct, read out of the Mutex) before deinit returns. The detached
        // task never holds a reference to self and is therefore safe to outlive it.
        let context = deinitContext.withLock { $0 }
        if let s = context.state {
            Task.detached { [context] in
                if let token = context.handlerToken {
                    await s.removeHandler(token) }
                if let appearedToken = context.appearedHandlerToken {
                    await s.removeAppearedHandler(appearedToken) }
                // No s.invalidate() call: initializeSWL no longer registers an NSWorkspace
                // observer, so there is nothing left for SWLState to tear down.
            }
        }
    }

    // MARK: – SWL start-up
    // Creates the SWL actor and registers this instance's handlers on it, then registers
    // the blacklisted applications that are already running. Idempotent: does nothing
    // while a start-up is in progress or once SWL is up.
    //
    // Formerly this ran once, inline in init(). A start-up that failed there — most
    // plausibly because the Accessibility grant was not in place at that instant — left
    // the instance permanently inert: swlState stayed nil, swlInitTask was cleared, and
    // no later preference change could revive it, because AppDelegate only constructs a
    // new instance when it holds none. Making the start-up restartable from
    // ensureSwlReady() means the next registration refresh simply tries again.
    private func startSWLIfNeeded() {
        guard swlState == nil, swlInitTask == nil, !isShutDown else { return }
        swlInitTask = Task {
            do {
                // Initialize SWL actor
                let state = try await initializeSWL()
                guard !self.isShutDown else {
                    log("SWL initialized after shutdown began — discarding.")
                    self.swlInitTask = nil
                    return }
                log("SWL initialized.")

                // Register a direct handler on the SWL actor. The @Sendable closure
                // cannot capture 'self' (a @MainActor class) directly, so it hops back
                // to the main actor via Task { @MainActor [weak self] in }, which is the
                // same pattern used by nsAppLaunched and nsAppTerminated. This replaces
                // the former NotificationCenter bridge (swlWindowDestroyed), eliminating
                // the post/observe round-trip and the dictionary boxing/unboxing of the
                // event's fields.
                let token = await state.addWindowDestroyedHandler { event in
                    Task { @MainActor [weak self] in
                        self?.handleWindowDestroyedEvent(event)
                    }
                }
                self.swlHandlerToken = token
                self.deinitContext.withLock { $0.handlerToken = token }    // Keep deinit context in sync
                log("Registered SWL destroyed handler (token: \(token)).")

                // Register a handler for WindowAppearedEvent. When a new window opens
                // in a monitored app, any pending quit task for that app is canceled
                // immediately — this is the definitive fix for the race condition where
                // opening a new file during the grace period caused the app to be quit.
                let appearedToken = await state.addWindowAppearedHandler { event in
                    Task { @MainActor [weak self] in
                        self?.handleWindowAppearedEvent(event)
                    }
                }
                self.swlAppearedHandlerToken = appearedToken
                self.deinitContext.withLock { $0.appearedHandlerToken = appearedToken }    // Keep deinit context in sync
                log("Registered SWL appeared handler (token: \(appearedToken)).")

                // Publish the state only now that both handlers are attached, so that no
                // wrapper can be installed against it (ensureSwlReady() returns as soon
                // as swlState is non-nil) while its handler table is still empty.
                self.swlState = state
                self.deinitContext.withLock { $0.state = state }    // Keep deinit context in sync

                // Mark the start-up as complete BEFORE the first registration pass, so
                // that ensureSwlReady() callers queued behind this task (a preference
                // refresh, an nsAppLaunched registration) resume against a fully wired
                // state rather than waiting out the whole pass.
                self.swlInitTask = nil

                // Register blacklisted apps currently running (and allow user
                // preferences to control enabling)
                await self.reconcileRegistrations()
            } catch {
                log("Failed to initialize SWL: \(error). AQ idle until the next registration refresh.")
                // Mark start-up done even on error; ensureSwlReady() will retry.
                self.swlInitTask = nil  } } }

    // MARK: – Registration helpers (AQ -> SWL)
    // Wait for SWL to be ready, starting it if a previous start-up failed. IMPORTANT:
    // Avoid deadlock by returning immediately if swlState is already set (this prevents
    // awaiting the current start-up task from inside itself).
    private func ensureSwlReady() async {
        // Already initialized — return immediately (prevents self-await deadlocks)
        if self.swlState != nil { return }
        startSWLIfNeeded()
        if let t = swlInitTask { await t.value } }

    // Brings SWL registrations into line with the preferences: every running instance
    // of a blacklisted application is monitored, nothing else is. AQ is the single
    // source of truth: Read Preferences.blacklistedApplications.
    //
    // This is a differential pass. The previous implementation unregistered every PID
    // and then registered from scratch on every blacklist edit, which tore down and
    // re-installed every AXObserver, re-seeded every baseline, and — because
    // unregistering cancels the PID's pending quit check — silently abandoned the grace
    // period of any application that was mid-way through one, even when that
    // application was still on the list. Now only PIDs that are no longer wanted are
    // torn down, and only PIDs not yet monitored are added; everything else, pending
    // checks included, is left exactly as it was.
    private func reconcileRegistrations() async {
        log("AQ: reconcileRegistrations() Entered")

        // ensureSwlReady returns immediately if swlState has already been set,
        // avoiding self-await deadlocks when called from inside the start-up Task.
        await ensureSwlReady()
        guard !isShutDown else { return }
        guard let s = swlState else {
            log("reconcileRegistrations: swlState missing."); return }

        // If quitting is disabled, don't monitor anything.
        guard Preferences.quitBlacklistedApplicationsEnabled else {
            log("reconcileRegistrations: Quitting disabled by preference; Unregistering everything.")
            await unregisterAllRegisteredPIDs()
            return }

        // Cache locally
        let blacklisted = Preferences.blacklistedApplications
        let blacklistBIDs = blacklisted.map { $0.bundleID }

        // ----- Begin diagnostic logging block -----
        if Logger.isLoggingEnabled {
            // Single snapshot; one compactMap pass for non-nil IDs. The display
            // string (with "<nil>" substitution) is produced inline from the same array.
            let runningApps = NSWorkspace.shared.runningApplications
            let runningBundleIDs = runningApps.compactMap { $0.bundleIdentifier }
            let runningBIDsDisplay = runningApps.map { $0.bundleIdentifier ?? "<nil>" }

            log("AQ: Blacklist bundle IDs: \(blacklistBIDs)")
            log("AQ: Running application bundle IDs: \(runningBIDsDisplay)")
            log("reconcileRegistrations: Currently running applications = [\(runningBundleIDs.joined(separator: ", "))]")

            // Show every running application and whether or not it is in the blacklist
            for inst in runningApps {
                let bid = inst.bundleIdentifier ?? "<nil>"
                if blacklistBIDs.contains(bid) {
                    log("AQ: Running app \(bid) (PID \(inst.processIdentifier)) IS in blacklist.")
                } else {
                    log("AQ: Running app \(bid) (PID \(inst.processIdentifier)) NOT in blacklist.") } } }
        // ----- End diagnostic logging block -----

        log("reconcileRegistrations: Found \(blacklisted.count) blacklisted entries in Preferences.")

        // Desired set: every live process of every blacklisted bundle ID.
        var desired: [pid_t: String] = [:]
        for bid in blacklistBIDs {
            for inst in NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            where !inst.isTerminated {
                desired[inst.processIdentifier] = bid } }

        // Drop what is no longer wanted: PIDs whose application was removed from the
        // blacklist, and PIDs whose process has gone without a termination notification
        // reaching us (both leave a wrapper that would otherwise linger indefinitely).
        for pid in registeredPIDs where desired[pid] == nil {
            log("reconcileRegistrations: PID \(pid) is no longer a blacklisted, running application — unregistering.")
            unregisterPID(pid, state: s) }
        for pid in Array(registrationAttempts.keys) where desired[pid] == nil {
            log("reconcileRegistrations: canceling in-flight registration for PID \(pid).")
            registrationAttempts.removeValue(forKey: pid)?.task.cancel() }

        // Add what is missing.
        for (pid, bid) in desired where !registeredPIDs.contains(pid) {
            beginRegistration(pid: pid, bundleID: bid, context: "reconcileRegistrations") } }

    // Starts a registration retry loop for a PID unless one is already running for it.
    private func beginRegistration(pid: pid_t, bundleID: String, context: String) {
        guard !isShutDown else { return }
        if registeredPIDs.contains(pid) {
            log("\(context): PID \(pid) already registered.")
            return }
        if registrationAttempts[pid] != nil {
            log("\(context): registration already in flight for PID \(pid).")
            return }
        log("\(context): Registering blacklisted app \(bundleID) (PID \(pid)).")
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.registerWithRetry(pid: pid, bundleID: bundleID, token: token) }
        registrationAttempts[pid] = RegistrationAttempt(token: token, task: task) }

    // Registers one PID with SWL, retrying a transient failure with backoff.
    //
    // An application that has only just launched frequently rejects AXObserver
    // registration (cannotComplete) until its accessibility server is up, and the
    // previous single attempt from nsAppLaunched then abandoned the application for
    // good — it was not monitored until the next blacklist edit or toggle. The delays
    // total roughly fifteen seconds, which comfortably covers a slow launch without
    // leaving a loop running for an application that will never accept an observer.
    // The loop re-validates its own preconditions on every pass: SWL still up, AQ still
    // enabled, the bundle still blacklisted, the process still alive.
    private func registerWithRetry(pid: pid_t, bundleID: String, token: UUID) async {
        defer {
            if registrationAttempts[pid]?.token == token {
                registrationAttempts.removeValue(forKey: pid) } }
        let delaysNanos: [UInt64] = [500_000_000, 1_000_000_000, 2_000_000_000,
                                     4_000_000_000, 8_000_000_000]
        var attempt = 0
        while true {
            attempt += 1
            await ensureSwlReady()
            guard !Task.isCancelled, !isShutDown, let s = swlState else { return }
            guard Preferences.quitBlacklistedApplicationsEnabled,
                  Preferences.blacklistedApplications.contains(where: { $0.bundleID == bundleID }) else {
                log("registerWithRetry: \(bundleID) (PID \(pid)) no longer eligible — abandoning.")
                return }
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                log("registerWithRetry: PID \(pid) is no longer running — abandoning.")
                return }
            if registeredPIDs.contains(pid) { return }

            switch await registerAppForMonitoring(pid: pid, state: s) {
            case .registered:
                // A shutdown or unregistration may have raced the install; honor it.
                guard !Task.isCancelled, !isShutDown else {
                    unregisterAppMonitoring(pid: pid, ownedBy: s)
                    return }
                registeredPIDs.insert(pid)
                log("registerWithRetry: SWL confirmed monitoring for PID \(pid) (bundle=\(bundleID)) on attempt \(attempt) — added to registeredPIDs.")
                return
            case .skipped:
                log("registerWithRetry: SWL declined to monitor PID \(pid) (bundle=\(bundleID)) — not a candidate.")
                return
            case .failed:
                guard attempt <= delaysNanos.count else {
                    log("registerWithRetry: SWL failed to confirm monitoring for PID \(pid) (bundle=\(bundleID)) after \(attempt) attempts — giving up.")
                    return }
                log("registerWithRetry: attempt \(attempt) failed for PID \(pid) (bundle=\(bundleID)) — retrying in \(Double(delaysNanos[attempt - 1]) / 1e9)s.")
                do { try await Task.sleep(nanoseconds: delaysNanos[attempt - 1]) }
                catch { return } } } }

    // Removes one PID from every table this instance keeps for it and from SWL.
    private func unregisterPID(_ pid: pid_t, state: SWLState) {
        registrationAttempts.removeValue(forKey: pid)?.task.cancel()
        unregisterAppMonitoring(pid: pid, ownedBy: state) // Global function in SWL.swift
        let key = Self.pendingKey(for: pid)
        if let work = pendingChecks.removeValue(forKey: key) {
            work.task.cancel()
            log("unregisterPID: canceled pending quit check for '\(key)'") }
        registeredPIDs.remove(pid) }

    // Unregister any PIDs AQ previously registered.
    private func unregisterAllRegisteredPIDs() async {
        await ensureSwlReady()
        guard let s = swlState else { log("unregisterAllRegisteredPIDs: swlState missing."); return }

        for (pid, attempt) in registrationAttempts {
            attempt.task.cancel()
            log("unregisterAllRegisteredPIDs: canceled in-flight registration for PID \(pid).") }
        registrationAttempts.removeAll()
        for pid in registeredPIDs {
            log("unregisterAllRegisteredPIDs: Requesting SWL to stop monitoring PID \(pid).")
            unregisterPID(pid, state: s) } }

    // Removes the pending-check entry for `key`, but only when it is still the check
    // identified by `token`. See the PendingCheck declaration for why the identity test
    // matters. A check that has been superseded simply leaves its successor's entry alone.
    private func clearPendingCheck(forKey key: String, token: UUID) {
        guard pendingChecks[key]?.token == token else { return }
        pendingChecks.removeValue(forKey: key) }

    // Schedule a serialized registration refresh (coalesces multiple calls).
    private func scheduleRegistrationRefresh() {
        guard !isShutDown else { return }
        // If a refresh is already running, mark that it needs to run again afterward.
        if registrationTask != nil { registrationNeedsRerun = true; return }

        registrationTask = Task { [weak self] in
            guard let self = self else { return }
            // Clear task reference on completion. ApplicationQuitter is @MainActor and
            // this Task runs on the main actor, so the assignment is safe without any
            // extra dispatch hop. The former 'Task { @MainActor in self.registrationTask = nil }'
            // wrapper captured self strongly and was redundant — both the defer closure
            // and the surrounding Task body already execute on the main actor.
            defer { self.registrationTask = nil }

            await self.reconcileRegistrations()

            // If asked to run again while running, do another pass. The call is
            // direct — no extra Task hop is needed because we are already on the
            // main actor.
            if self.registrationNeedsRerun {
                self.registrationNeedsRerun = false
                self.scheduleRegistrationRefresh() } } }

    // MARK: – NSWorkspace observers
    // Called when any app launches to register it if it is blacklisted.
    @objc private func nsAppLaunched(_ note: Notification) {
        guard !isShutDown, Preferences.quitBlacklistedApplicationsEnabled else { return }
        guard let nsapp = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        // Capture only sendable values before creating a Task.
        guard let bid = nsapp.bundleIdentifier else { return }
        let pid = nsapp.processIdentifier

        // Cache locally
        let blacklisted = Preferences.blacklistedApplications

        log("AQ: nsAppLaunched detected app \(bid) (PID \(pid)).")
        log("AQ: Current blacklist bundle IDs: \(blacklisted.map { $0.bundleID })")

        if blacklisted.contains(where: { $0.bundleID == bid }) {
            beginRegistration(pid: pid, bundleID: bid, context: "nsAppLaunched") } }

    // Called when any app terminates to keep registeredPIDs and pendingChecks consistent.
    @objc private func nsAppTerminated(_ note: Notification) {
        guard let nsapp = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = nsapp.processIdentifier

        registrationAttempts.removeValue(forKey: pid)?.task.cancel()

        if registeredPIDs.contains(pid) {
            registeredPIDs.remove(pid)
            log("nsAppTerminated: Removed PID \(pid) from registeredPIDs due to termination.") }

        // Cancel any pending quit check for this terminated app.
        let key = Self.pendingKey(for: pid)
        if let work = pendingChecks.removeValue(forKey: key) {
            work.task.cancel()
            log("nsAppTerminated: Canceled pending quit check for '\(key)' due to termination.") }

        // Ask SWL to remove any wrapper for this PID (best-effort). Scoped to this
        // instance's state so a late notification cannot dismantle a wrapper that a newer
        // instance owns for a recycled PID. This no longer awaits ensureSwlReady(): a
        // wrapper can only have been installed under a state that already exists, so if
        // swlState is nil there is nothing of ours to remove — and ensureSwlReady() would
        // now (re)start SWL, which a termination notification has no business doing.
        if let s = swlState {
            unregisterAppMonitoring(pid: pid, ownedBy: s)
            log("nsAppTerminated: Removed SWL monitoring for PID \(pid).") } }

    // MARK: – AQ policy
    // Cancels any pending quit for an app immediately when a new window appears in it.
    // This is the primary fix for the race condition: if the user opens a new file
    // during the grace period, this handler fires before the quit task wakes and
    // cancels it without waiting for the sleep to expire.
    // This method is synchronous and non-async — it only reads and mutates
    // @MainActor-isolated state, with no actor hops required.
    private func handleWindowAppearedEvent(_ event: WindowAppearedEvent) {
        guard Preferences.quitBlacklistedApplicationsEnabled else { return }

        let key = Self.pendingKey(for: event.pid)
        if let existing = pendingChecks.removeValue(forKey: key) {
            existing.task.cancel()
            log("WindowAppearedEvent: Canceled pending quit for '\(key)' — new window detected (count=\(event.knownWindowsCountAfterAddition)).")
        }
    }

    // Core quitting logic — called directly from the SWL handler via Task { @MainActor }.
    private func handleWindowDestroyedEvent(_ event: WindowDestroyedEvent) {
        // Only operate if AQ quitting preference is enabled
        guard !isShutDown, Preferences.quitBlacklistedApplicationsEnabled else { return }

        // Cache locally
        let blacklisted = Preferences.blacklistedApplications

        // Single source of truth: Only act for bundleIDs present in Preferences-based blacklist
        if let bid = event.bundleID {
            guard blacklisted.contains(where: { $0.bundleID == bid }) else {
                log("Received SWL event for \(bid) which is not in Preferences-based blacklist — ignoring.")
                return }
        } else {
            // Event without bundleID: Still allow PID-based handling if we registered the PID
            if !registeredPIDs.contains(event.pid) {
                log("Received SWL event for PID \(event.pid) which AQ did not register — ignoring.")
                return } }

        // If there are still some windows, do nothing
        if event.knownWindowsCountAfterRemoval > 0 {
            log("SWL event: PID \(event.pid) still has \(event.knownWindowsCountAfterRemoval) windows — skipping quit.")
            return }

        let key = Self.pendingKey(for: event.pid)
        if let existing = pendingChecks.removeValue(forKey: key) {
            existing.task.cancel()
            log("Canceled prior pending quit check for '\(key)'.") }

        // Debounce + re-check knownWindows via actor before quitting.
        //
        // A single Task replaces the former DispatchWorkItem + inner Task double-wrap.
        // ApplicationQuitter is @MainActor, so 'Task { ... }' created here already runs
        // on the main actor — no DispatchQueue hop is needed. Task.isCancelled is checked
        // after the sleep so a cancellation (AQ disabled, app already quit) that arrives
        // during the grace delay exits cleanly without attempting a quit.
        let pid = event.pid
        let bundleID = event.bundleID
        // Identifies this specific check, so its own cleanup cannot evict a successor's
        // entry. See PendingCheck / clearPendingCheck(forKey:token:).
        let token = UUID()
        let task = Task { [weak self] in
            do {
                // Read the grace delay live at scheduling time so preference changes
                // take effect on the next quit cycle without requiring a restart.
                let graceDelay = Preferences.aqGraceDelaySeconds
                try await Task.sleep(
                    nanoseconds: UInt64(Double(graceDelay) * 1_000_000_000))
            } catch { return } // Sleep canceled — exit without quitting.

            guard !Task.isCancelled, let self else { return }
            // Every early return below must release this check's entry, or a finished
            // task would be left in the table and handleWindowAppearedEvent would later
            // log a "canceled pending quit" for a check that was no longer pending.
            defer { self.clearPendingCheck(forKey: key, token: token) }

            guard self.swlState != nil, !self.isShutDown else {
                Self.log("Delayed quit check: swlState not available for PID \(pid).")
                return }

            // The preferences may have changed during the grace period. A disable
            // cancels this task outright and a blacklist removal unregisters the PID
            // (also canceling it), so these are belt-and-braces — but they are cheap,
            // and the action below is not reversible.
            guard Preferences.quitBlacklistedApplicationsEnabled else {
                Self.log("Delayed quit check: AQ disabled during grace period for PID \(pid) — aborting quit.")
                return }
            if let bundleID,
               !Preferences.blacklistedApplications.contains(where: { $0.bundleID == bundleID }) {
                Self.log("Delayed quit check: \(bundleID) no longer blacklisted — aborting quit for PID \(pid).")
                return }

            // Re-verify directly against AX rather than trusting SWLState's cached
            // snapshot. The cache is only ever as current as the last notification or
            // diff that updated it, and a known AX limitation can cause a single
            // kAXWindowsAttribute read to transiently omit a window that is on another
            // Space (or was just recreated) — the cache can be affected by that same
            // class of glitch. Because this decision is destructive and irreversible,
            // the quit proceeds only once two time-separated live reads have BOTH come
            // back empty. Two independent AX misses in quick succession are far less
            // likely than one, so this filters out the one-off glitch that previously
            // let this recheck confirm a false "zero windows" state.
            //
            // A read that produces no answer at all (timeout, or an AX error such as
            // cannotComplete from an application that is momentarily busy) is neither
            // an empty nor a non-empty result. Rather than abandon the quit on the first
            // such read — which left the application sitting windowless until some later
            // window event happened to arrive — up to two indeterminate reads are
            // tolerated within the sequence; only if two definitive empties are never
            // obtained is the quit abandoned as a precaution.
            let maxReads = 4
            var emptyReads = 0
            var reads = 0
            var confirmedEmpty = false
            while reads < maxReads {
                if reads > 0 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if Task.isCancelled || self.isShutDown {
                        // A WindowAppearedEvent (or teardown) arrived during reconfirmation.
                        return } }
                reads += 1
                guard let snapshot = await liveWindowSnapshot(for: pid) else {
                    Self.log("Delayed quit check: live AX read \(reads) for PID \(pid) was indeterminate (timeout or AX error).")
                    continue }
                if !snapshot.isEmpty {
                    Self.log("Delayed quit check: live AX read \(reads) found \(snapshot.count) window(s) for PID \(pid) — aborting quit.")
                    return }
                emptyReads += 1
                Self.log("Delayed quit check: live AX read \(reads) found no windows for PID \(pid).")
                if emptyReads >= 2 { confirmedEmpty = true; break } }

            guard confirmedEmpty else {
                Self.log("Delayed quit check: could not obtain two definitive empty reads for PID \(pid) (\(emptyReads) empty of \(reads)) — aborting quit as a precaution.")
                return }

            // Bookkeeping is deliberately NOT touched here. terminate() returning true
            // means only that the Quit Apple event was delivered, not that the
            // application has quit — it may still be showing a save sheet, and the user
            // may cancel it. Both terminate() and forceTerminate() are asynchronous, and
            // the authoritative signal that the process is gone is
            // NSWorkspace.didTerminateApplicationNotification, which nsAppTerminated
            // already turns into the registeredPIDs / SWL cleanup. Removing the PID here
            // used to leave an application that declined to quit alive but absent from
            // registeredPIDs, with its wrapper still installed and reporting.
            // Last look before the irreversible step: a WindowAppearedEvent that landed
            // between the final read and here has canceled this task.
            guard !Task.isCancelled, !self.isShutDown else { return }
            guard let runningApp = NSRunningApplication(processIdentifier: pid), !runningApp.isTerminated else {
                Self.log("SWL-confirmed: Application for PID \(pid) not found (already quit).")
                return }
            Self.log("SWL-confirmed: Attempting graceful quit for PID \(pid).")
            if runningApp.terminate() {
                Self.log("Graceful terminate() returned true for PID \(pid).")
            } else {
                // Termination request could not be delivered; log and fall back to force-quit.
                Self.log("Graceful terminate() returned false — forcing termination for PID \(pid).")
                if !runningApp.forceTerminate() {
                    Self.log("forceTerminate() returned false for PID \(pid) — the application remains monitored.") } } }

        pendingChecks[key] = PendingCheck(token: token, task: task)
        log("Scheduled quit check for '\(key)' in \(Preferences.aqGraceDelaySeconds)s.") }

    // MARK: – Preferences refresh
    // Called by AppDelegate whenever a key relevant to AQ changes.
    // ApplicationQuitter is @MainActor-isolated, so this method already runs on the
    // main actor. The 'Task { @MainActor in }' wrapper that previously surrounded the
    // body was redundant — it scheduled the work as a new task rather than executing
    // inline, which prevented callers from relying on teardown starting synchronously.
    // The async helpers are now called from a stored Task so the public API stays
    // non-async while still supporting the structured concurrency model.
    func refreshFromPreferences() {
        if Preferences.quitBlacklistedApplicationsEnabled {
            log("AQ enabled by preference — refreshing SWL registrations.")
            scheduleRegistrationRefresh()
        } else {
            log("AQ disabled by preference — canceling pending checks and unregistering.")
            // From here on this instance only ever tears down; see isShutDown.
            isShutDown = true
            // Cancel pending checks immediately
            pendingChecks.values.forEach { $0.task.cancel() }
            pendingChecks.removeAll()
            // Cancel any running registration task
            registrationTask?.cancel()
            registrationTask = nil
            registrationNeedsRerun = false
            // Kick off the async unregistration pass as a Task since we cannot await
            // directly in a non-async method.
            Task { await unregisterAllRegisteredPIDs() }
        }
    }
}
