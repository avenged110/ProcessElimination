// MARK: – SWL.swift
// Copyright © 2025 avenged110.
// Portions Copyright (c) 2017 Tyler Mandry (Swindler, https://github.com/tmandry/Swindler).
// SPDX-License-Identifier: GPL-3.0-only AND MIT
// Adapted from the necessary pieces of Swindler and modified by avenged110, 2025. The MIT
// portions are subject to the notice in NOTICES/Swindler-MIT.txt.
// Minimal, self-contained AXObserver + snapshot/diff support for AQ.swift.

import Foundation
import AppKit
import ApplicationServices
import Synchronization

// MARK: – Public API

// Explicit Sendable conformances are required because these structs cross actor and
// Task boundaries throughout this file. All stored properties are value types or
// Sendable themselves, so synthesis is safe and correct.
public struct WindowDestroyedEvent: Sendable {
    public let pid: pid_t
    public let bundleID: String?
    public let windowID: String
    public let knownWindowsCountAfterRemoval: Int }

// Emitted by SWL whenever a new window is detected for a monitored process.
// AQ uses this event to cancel any pending quit task for the app, preventing
// the race condition where a new file is opened in the grace-delay window.
public struct WindowAppearedEvent: Sendable {
    public let pid: pid_t
    public let bundleID: String?
    public let windowID: String
    public let knownWindowsCountAfterAddition: Int }

// SwWindow carries only the stable identity needed for window-set diffing.
// title and frame are intentionally absent: no consumer reads them, and omitting
// the corresponding AX attribute fetches reduces per-callback IPC overhead.
//
// `element` is the window's AXUIElement itself. AXUIElement implements CFEqual/CFHash
// on the underlying accessibility token, so two references to the same window compare
// equal and can be used directly as Set members — exact identity, with no possibility
// of two distinct windows colliding on a hash value. `id` is a human-readable form of
// that identity for events and log lines only; it is never used for matching.
//
// AXUIElement is a CF type without a Sendable conformance. The reference is an
// immutable handle (a token, not a live object) that AX itself hands across threads,
// so `@unchecked Sendable` is sound here.
public struct SwWindow: @unchecked Sendable, Hashable {
    public let element: AXUIElement
    public var id: String { String(CFHash(element)) } }

// Actor state: the registry of window-event handlers.
//
// SWLState used to also carry a `[pid_t: SwApp]` snapshot of every monitored app's
// window set, rebuilt through `setApp` on every AX callback. It has been removed: its
// only remaining reader was `bundleIDForPID`, which NSRunningApplication answers
// directly, and `getKnownWindowCount` had no callers at all — ApplicationQuitter
// deliberately re-verifies against live AX before quitting rather than trusting a
// cached count. Maintaining it cost an actor round-trip on every window create and
// destroy for a value nothing consulted.
public actor SWLState {
    fileprivate var handlers: [UUID: @Sendable (WindowDestroyedEvent) -> Void] = [:]
    fileprivate var appearedHandlers: [UUID: @Sendable (WindowAppearedEvent) -> Void] = [:]

    public init() {}

    // Register a handler to be called when SWL observes window destruction. Handler must
    // be @Sendable and should be lightweight; SWL dispatches handlers on main thread.
    public func addWindowDestroyedHandler(
        _ handler: @Sendable @escaping (WindowDestroyedEvent) -> Void
    ) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id }

    public func removeHandler(_ token: UUID) { handlers.removeValue(forKey: token) }

    // Register a handler to be called when SWL detects a new window for a monitored
    // process. AQ uses this to cancel any pending quit task when the user opens a new
    // file in an app whose last window was recently closed.
    public func addWindowAppearedHandler(
        _ handler: @Sendable @escaping (WindowAppearedEvent) -> Void
    ) -> UUID {
        let id = UUID()
        appearedHandlers[id] = handler
        return id }

    public func removeAppearedHandler(_ token: UUID) {
        appearedHandlers.removeValue(forKey: token) }

    // Called internally by SWL to notify registered handlers.
    // All callers reach this method via 'Task { await stateRef?.emitWindowDestroyed(ev) }'
    // inside AXObserverWrapper._handleAXCallback, which is itself @MainActor-isolated.
    // The handlers are therefore always invoked on the main actor without any extra
    // dispatch; the former DispatchQueue.main.async wrapper has been removed as it
    // added an unnecessary run-loop round-trip and latency.
    fileprivate func emitWindowDestroyed(_ event: WindowDestroyedEvent) {
        let localHandlers = Array(handlers.values)
        for h in localHandlers { h(event) } }

    // Called internally by SWL when a new window is detected for a monitored process.
    fileprivate func emitWindowAppeared(_ event: WindowAppearedEvent) {
        let localHandlers = Array(appearedHandlers.values)
        for h in localHandlers { h(event) } }

}

// MARK: – Logging
fileprivate func log(_ message: String) {
    if Logger.isLoggingEnabled { Logger.log(message, cName: "[SWL]") } }

// MARK: – Initialization
public enum SWLError: Error {
    case accessibilityNotTrusted
    case initializationFailed(String)
    // An AX attribute read answered with an error rather than a value. The associated
    // value is the raw AXError code. See fetchAXWindows for which codes are treated as a
    // definitive "no windows" answer and which are treated as indeterminate.
    case axError(Int32) }

// Initialize SWL. Caller must have AX permission already.
// @MainActor because it registers an NSWorkspace observer and calls
// unregisterAppMonitoring, both of which are @MainActor-bound.
@MainActor
public func initializeSWL() async throws -> SWLState {
    guard AXIsProcessTrusted() else {
        log("AXIsProcessTrusted() == false — cannot start SWL.")
        throw SWLError.accessibilityNotTrusted }

    let state = SWLState()

    // No NSWorkspace observer is registered here any more. The one that used to live at
    // this point did nothing but write a log line — application termination is handled
    // authoritatively by ApplicationQuitter.nsAppTerminated, which cancels the pending
    // quit check and calls unregisterAppMonitoring. It existed only so that a token could
    // be handed to SWLState.invalidate(), and that whole chain (ObserverTokenBox, the
    // stored token, invalidate(), and AQ's deinit call to it) existed only to remove an
    // observer that had no effect. All of it is gone.
    log("initializeSWL(): Started; Awaiting AQ to register blacklisted applications.")
    return state
}

// MARK: – Registry
// Internal registry of AXObserver wrappers per PID (only for AQ-registered PIDs).
// @MainActor isolation enforces that all reads and writes happen on the main actor,
// replacing the previous undocumented "all callers happen to be on main" invariant
// with a hard compiler-verified guarantee.
@MainActor fileprivate var unifiedRegistry: [pid_t: AXObserverWrapper] = [:]

// Outcome of registerAppForMonitoring. The distinction between `.skipped` and `.failed`
// matters to the caller: a skip is a property of the process (it is the host, it has no
// UI, or it is not running at all) and will not change by trying again, whereas a
// failure is an AX-level refusal that is frequently transient — an application that has
// only just launched routinely answers AXObserverAddNotification with cannotComplete
// for its first few hundred milliseconds — and is worth retrying after a short delay.
public enum SWLRegistrationResult: Sendable {
    // A wrapper is installed for the PID and bound to the caller's SWLState.
    case registered
    // The PID is not a candidate for monitoring; do not retry.
    case skipped
    // AXObserver creation or notification registration failed; may succeed later.
    case failed }

// Register a PID for SWL monitoring. @MainActor because it reads and writes
// unifiedRegistry and constructs/installs AXObserverWrapper, all of which must run
// on the main actor.
//
// `unifiedRegistry` is a process-wide table that outlives any single ApplicationQuitter
// instance, while each instance owns its own SWLState. A wrapper found in the table is
// only "already registered" when it delivers to the caller's state; one left behind by a
// previous AQ instance (its state gone, or a different object) delivers to nobody the
// caller can hear, so it is torn down and replaced rather than reported as a success.
@MainActor
public func registerAppForMonitoring(pid: pid_t, state: SWLState) async -> SWLRegistrationResult {
    if let existing = unifiedRegistry[pid] {
        if existing.stateRef === state {
            log("registerAppForMonitoring: PID \(pid) already registered; skipping")
            return .registered }
        log("registerAppForMonitoring: PID \(pid) has a wrapper bound to a stale SWLState — replacing it")
        existing.invalidate()
        unifiedRegistry.removeValue(forKey: pid) }

    if pid == ProcessInfo.processInfo.processIdentifier {
        log("registerAppForMonitoring: Skipping host PID \(pid)")
        return .skipped }

    guard let nsapp = NSRunningApplication(processIdentifier: pid), !nsapp.isTerminated else {
        log("registerAppForMonitoring: No running application for PID \(pid)")
        return .skipped }

    if nsapp.activationPolicy == .prohibited {
        log("registerAppForMonitoring: PID \(pid) activationPolicy prohibited — skipping")
        return .skipped }

    let bundleID = nsapp.bundleIdentifier

    let wrapper = AXObserverWrapper(pid: pid, bundleID: bundleID, state: state)
    let started = wrapper.install()

    if started {
        unifiedRegistry[pid] = wrapper
        log("registerAppForMonitoring: Installed wrapper for PID \(pid) bundle=\(bundleID ?? "unknown")")
        return .registered
    } else {
        log("registerAppForMonitoring: Wrapper installation failed for PID \(pid) bundle=\(bundleID ?? "unknown")")
        return .failed }
}

// Remove SWL monitoring for a PID. @MainActor because it reads and writes
// unifiedRegistry and calls invalidate() on the wrapper.
//
// When `ownedBy` is given, only a wrapper bound to that SWLState (or to none — its
// state has already been deallocated) is removed. This keeps a lingering task on an
// ApplicationQuitter instance that is being torn down from dismantling a wrapper that
// a newer instance has since installed for the same PID.
@MainActor
public func unregisterAppMonitoring(pid: pid_t, ownedBy state: SWLState? = nil) {
    guard let wrap = unifiedRegistry[pid] else {
        log("unregisterAppMonitoring: PID \(pid) not registered — nothing to do")
        return }
    if let state, let owner = wrap.stateRef, owner !== state {
        log("unregisterAppMonitoring: PID \(pid) is owned by a different SWLState — leaving it in place")
        return }
    wrap.invalidate()
    unifiedRegistry.removeValue(forKey: pid)
    log("unregisterAppMonitoring: Removed wrapper for pid \(pid)")
}

// MARK: – AXObserver wrapper
// Snapshot/diff + destroyed-notification handling.
//
// @MainActor isolation is the correct model here: every method — install(),
// _handleAXCallback(), invalidate() — must run on the main thread because they
// all touch AXObserver run-loop registration, unifiedRegistry, and previousIDs.
// Annotating the class with @MainActor makes the compiler verify this invariant
// instead of relying on undocumented dispatch conventions, and eliminates the
// Sendable warnings that arose when the non-Sendable class was captured across
// concurrency boundaries.
@MainActor
fileprivate final class AXObserverWrapper {
    let pid: pid_t
    let bundleID: String?
    // The set of windows this wrapper currently believes exist. Members are the windows'
    // AXUIElements, compared by CFEqual (see SwWindow).
    private var previousIDs: Set<SwWindow> = []
    private var observer: AXObserver?
    private var runLoopSource: CFRunLoopSource?
    // weak to avoid a retain cycle between the wrapper and the actor.
    private(set) weak var stateRef: SWLState?

    // Set by invalidate(). The C callback hops to the main actor through a Task, and the
    // seed and snapshot-diff paths suspend across an AX fetch, so any of them can resume
    // after the wrapper has been removed from the registry. Once this is set they all
    // return without touching state or emitting events — the PID is no longer monitored,
    // and a stale event here could otherwise schedule a quit check for an application
    // that was just removed from the blacklist.
    private var isInvalidated = false

    // Bumped every time previousIDs is mutated, by any path (fast-path create/destroy
    // notification, the snapshot-diff fallback below, or the baseline seed). The snapshot
    // paths' AX fetch is asynchronous and can take a perceptible amount of time; if a
    // fast-path notification updates previousIDs while that fetch is still in flight, the
    // fetch's eventual result no longer reflects a consistent "before" state to diff
    // against. Capturing this counter immediately before starting a snapshot fetch and
    // comparing it again afterward lets that code path detect — and safely discard — a
    // diff that has been overtaken by fresher, more authoritative information, instead of
    // silently overwriting previousIDs with stale data and fabricating a bogus
    // appeared/destroyed event for a window that the fast path has already accounted for
    // correctly.
    private var stateVersion: UInt64 = 0

    // Timeout for AX snapshot reads (nanoseconds).
    private let snapshotTimeoutNanos: UInt64 = 2 * 1_000_000_000 // 2 seconds

    init(pid: pid_t, bundleID: String?, state: SWLState) {
        self.pid = pid
        self.bundleID = bundleID
        self.stateRef = state }

    // Returns true if the AXObserver was created and registered successfully.
    func install() -> Bool {
        var obsPtr: AXObserver?

        // The AXObserver C callback is a plain function pointer — it cannot be
        // @MainActor — so we bounce back to the main actor immediately via Task.
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon = unsafe refcon else { return }
            let wrapper = unsafe Unmanaged<AXObserverWrapper>.fromOpaque(refcon).takeUnretainedValue()
            // wrapper is @MainActor-isolated; Task { @MainActor in } ensures we
            // resume on the main actor before touching any wrapper state.
            Task { @MainActor in
                wrapper._handleAXCallback(element: element, notification: notification) } }

        let err = unsafe AXObserverCreate(self.pid, callback, &obsPtr)
        guard err == .success, let obs = obsPtr else {
            log("(\(self.pid)) AXObserverCreate failed (err=\(err.rawValue)). Will not monitor this PID.")
            return false }

        self.observer = obs

        let axApp = AXUIElementCreateApplication(self.pid)

        // Only subscribe to notifications that can indicate a window was created or
        // destroyed. Move and resize notifications are deliberately excluded — they
        // cannot change the set of existing windows and would only generate snapshot
        // tasks whose 'removed' diff is always empty.
        //
        // The first two are the fast path and are essential: without them the wrapper
        // would only ever learn about windows through the focus/main-changed snapshot
        // diff. A *hard* failure to register either one — cannotComplete, the usual
        // answer from an application that has not finished bringing up its AX server,
        // or apiDisabled / invalidUIElement / failure — therefore fails the install as a
        // whole, so that the caller can retry instead of being left with a wrapper that
        // reports success and delivers nothing. An application that simply does not
        // support the notification (notificationUnsupported / notImplemented) is not a
        // failure: retrying cannot help, and it is still monitored through the diff path
        // exactly as it always was. The remaining two only improve coverage.
        let essential: [String] = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification]
        let optional: [String] = [
            kAXMainWindowChangedNotification,
            kAXFocusedWindowChangedNotification]
        let tolerated: Set<AXError> = [
            .success, .notificationAlreadyRegistered, .notificationUnsupported, .notImplemented]

        for notif in essential {
            let addErr = unsafe AXObserverAddNotification(
                obs, axApp, notif as CFString,
                Unmanaged.passUnretained(self).toOpaque())
            guard tolerated.contains(addErr) else {
                log("(\(pid)) AXObserverAddNotification '\(notif)' -> err=\(addErr.rawValue); install failed")
                self.observer = nil
                return false }
            if addErr != .success {
                log("(\(pid)) AXObserverAddNotification '\(notif)' -> err=\(addErr.rawValue)") } }

        for notif in optional {
            let addErr = unsafe AXObserverAddNotification(
                obs, axApp, notif as CFString,
                Unmanaged.passUnretained(self).toOpaque())
            if addErr != .success {
                log("(\(pid)) AXObserverAddNotification '\(notif)' -> err=\(addErr.rawValue)") } }

        let src: CFRunLoopSource = AXObserverGetRunLoopSource(obs)
        self.runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, CFRunLoopMode.defaultMode)

        // Seed the baseline window set. Task { @MainActor [weak self] in } stays on
        // the main actor throughout (no DispatchQueue hop needed). The actual AX fetch
        // suspends inside snapshotWithTimeout via a child task off the main actor.
        //
        // The notifications above are live from this point on, so a fast-path event can
        // arrive while the seed fetch is still in flight. The seed used to assign the
        // fetched set unconditionally, which would then drop a window the fast path had
        // just added (its later destruction went unnoticed — no event, no quit) or
        // resurrect one the fast path had just removed. It now uses the same
        // stateVersion guard as the diff path: a fetch overtaken by a fast-path update is
        // discarded and repeated, and only a fetch that observed a quiescent state is
        // assigned. After a few overtaken or indeterminate attempts, the best available
        // information is merged instead: the fast path's entries are kept and the fetched
        // windows (if any) are added to them, which errs toward counting a window that
        // may be gone — the pending quit check re-verifies against live AX before acting,
        // so an overcount can only delay a quit, never cause a wrong one.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let maxAttempts = 3
            var lastSnapshot: [SwWindow]? = nil
            for attempt in 1...maxAttempts {
                let expectedVersion = self.stateVersion
                let snapshotOpt = await self.snapshotWithTimeout()
                guard !self.isInvalidated else { return }
                if let snapshot = snapshotOpt {
                    lastSnapshot = snapshot
                    if self.stateVersion == expectedVersion {
                        self.previousIDs = Set(snapshot)
                        self.stateVersion &+= 1
                        log("(\(self.pid)) AXObserver installed; Seeded \(self.previousIDs.count) baseline windows for bundle=\(self.bundleID ?? "unknown")")
                        return }
                    log("(\(self.pid)) Baseline seed attempt \(attempt) overtaken by a fast-path notification — retrying")
                } else {
                    log("(\(self.pid)) Baseline seed attempt \(attempt) indeterminate (timeout or AX error) — retrying") }
            }
            // Fallback: merge rather than overwrite.
            if let snapshot = lastSnapshot { self.previousIDs.formUnion(snapshot) }
            self.stateVersion &+= 1
            log("(\(self.pid)) AXObserver installed; Baseline merged after \(maxAttempts) attempts — \(self.previousIDs.count) windows for bundle=\(self.bundleID ?? "unknown")") }

        return true }

    // Internal AX callback handler — always runs on the main actor (enforced by the
    // Task { @MainActor in } hop in the C callback above).
    func _handleAXCallback(element: AXUIElement?, notification: CFString?) {
        guard !isInvalidated else { return }
        let notifString = notification as String?

        // Destroyed notification for a specific element is authoritative.
        if notifString == kAXUIElementDestroyedNotification as String {
            if let el = element {
                let removed = SwWindow(element: el)
                if previousIDs.contains(removed) {
                    previousIDs.remove(removed)
                    stateVersion &+= 1
                    let remaining = previousIDs.count
                    let ev = WindowDestroyedEvent(
                        pid: self.pid, bundleID: self.bundleID,
                        windowID: removed.id,
                        knownWindowsCountAfterRemoval: remaining)
                    Task { await self.stateRef?.emitWindowDestroyed(ev) } } }
            return }

        // Window-created notification: emit a WindowAppearedEvent immediately using the
        // element as its identity. This is the authoritative fast path — it fires as
        // soon as the AX server signals the new window, before any snapshot round-trip.
        // If the element was not previously tracked, add it to previousIDs so the
        // snapshot-diff path stays consistent and does not re-emit an appeared event for
        // the same window on the next snapshot.
        if notifString == kAXWindowCreatedNotification as String {
            if let el = element {
                let added = SwWindow(element: el)
                if !previousIDs.contains(added) {
                    previousIDs.insert(added)
                    stateVersion &+= 1
                    let newCount = previousIDs.count
                    let ev = WindowAppearedEvent(
                        pid: self.pid, bundleID: self.bundleID,
                        windowID: added.id,
                        knownWindowsCountAfterAddition: newCount)
                    Task { await self.stateRef?.emitWindowAppeared(ev) }
                    log("(\(self.pid)) WindowAppearedEvent emitted via kAXWindowCreatedNotification; count=\(newCount) bundle=\(self.bundleID ?? "unknown")")
                }
            }
            return }

        // For all other notifications (main window changed, focused window changed),
        // perform a timed snapshot. Task { @MainActor } stays on the main actor so
        // previousIDs mutations are always actor-isolated; the actual AX fetch suspends
        // inside snapshotWithTimeout via a child task.
        //
        // expectedVersion is captured synchronously, here, before the async fetch begins.
        // If a fast-path create/destroy notification arrives and mutates previousIDs while
        // this fetch is in flight, stateVersion will have moved on by the time we resume,
        // and the guard below discards this result rather than diffing against — and
        // overwriting — a previousIDs value that a more authoritative source has already
        // updated correctly.
        let expectedVersion = self.stateVersion
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let snapshot = await self.snapshotWithTimeout() else {
                log("(\(self.pid)) AX snapshot unavailable (timeout or AX error) — skipping change processing for bundle=\(self.bundleID ?? "unknown")")
                return }
            guard !self.isInvalidated else { return }

            guard self.stateVersion == expectedVersion else {
                log("(\(self.pid)) Discarding stale snapshot diff — a fast-path notification already updated state during the fetch (bundle=\(self.bundleID ?? "unknown")).")
                return }

            let currentIDs = Set(snapshot)
            let removed = self.previousIDs.subtracting(currentIDs)
            let added   = currentIDs.subtracting(self.previousIDs)
            guard !removed.isEmpty || !added.isEmpty else { return }
            self.previousIDs = currentIDs
            self.stateVersion &+= 1

            // Emit appeared events for any windows that showed up in this diff but were
            // not already caught by the kAXWindowCreatedNotification fast path above.
            if !added.isEmpty {
                log("(\(self.pid)) detected addition(s) via snapshot diff: count=\(added.count) bundle=\(self.bundleID ?? "unknown")")
                for addedWindow in added {
                    let ev = WindowAppearedEvent(
                        pid: self.pid, bundleID: self.bundleID,
                        windowID: addedWindow.id,
                        knownWindowsCountAfterAddition: currentIDs.count)
                    await self.stateRef?.emitWindowAppeared(ev) } }

            if !removed.isEmpty {
                log("(\(self.pid)) detected removal(s): Count=\(removed.count) bundle=\(self.bundleID ?? "unknown")")
                for removedWindow in removed {
                    let ev = WindowDestroyedEvent(
                        pid: self.pid, bundleID: self.bundleID,
                        windowID: removedWindow.id,
                        knownWindowsCountAfterRemoval: currentIDs.count)
                    await self.stateRef?.emitWindowDestroyed(ev) } } } }

    // Races a real AX window fetch against a hard timeout.
    // Returns nil  → timeout fired before the fetch completed, or AX answered with an
    //                error (snapshot unavailable / indeterminate).
    // Returns []   → fetch completed successfully but the app has no windows.
    //
    // This is now a thin alias for liveWindowSnapshot(for:timeoutNanos:), which had a
    // byte-for-byte duplicate of the same race. One implementation means one place for
    // the timeout semantics to be right.
    private func snapshotWithTimeout() async -> [SwWindow]? {
        await liveWindowSnapshot(for: self.pid, timeoutNanos: self.snapshotTimeoutNanos) }

    // The run-loop source carries an unretained pointer to this wrapper (the AXObserver
    // refcon). Every current removal path calls invalidate() first, but if a wrapper were
    // ever dropped without it, the source would go on delivering callbacks into freed
    // memory. Removing it here makes that impossible rather than merely avoided. Both
    // this deinit and the callback run on the main thread, so they cannot overlap.
    isolated deinit {
        if let src = self.runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, CFRunLoopMode.defaultMode) } }

    func invalidate() {
        isInvalidated = true
        if let src = self.runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, CFRunLoopMode.defaultMode) }
        self.observer = nil
        self.runLoopSource = nil }
}

// MARK: – AX snapshot helper
// nonisolated free function: no shared mutable state, only local variables and
// CF/AX calls. Safe to call from any concurrency context.
//
// The result distinguishes "the application answered, and it has no windows" from "no
// answer was obtained". Only the former is returned as []. Every AX error other than
// noValue / attributeUnsupported (both of which are the application's own way of saying
// "nothing here") is thrown instead: cannotComplete (busy or still launching),
// apiDisabled (the Accessibility grant was revoked), invalidUIElement (the process is
// gone), and notImplemented (the process has no accessibility support at all — a
// command-line tool, say) all used to come back as [], which is precisely the value
// that authorizes a quit. A caller making that decision must treat a throw as
// "unknown", not as "zero".
fileprivate func fetchAXWindows(for pid: pid_t, timeoutNanos: UInt64) throws -> [SwWindow] {
    let axApp = AXUIElementCreateApplication(pid)
    // Bound the synchronous read itself to the caller's deadline. The racing timeout in
    // liveWindowSnapshot abandons a hung read, but the detached task running it would
    // otherwise keep a cooperative-pool thread blocked for AX's global default (~6 s),
    // and focus changes produce these reads in bursts.
    AXUIElementSetMessagingTimeout(axApp, Float(Double(timeoutNanos) / 1e9))
    var value: CFTypeRef?
    let err = unsafe AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
    switch err {
    case .success: break
    case .noValue, .attributeUnsupported: return []
    default: throw SWLError.axError(err.rawValue) }
    guard let value else { return [] }

    // Toll-free bridging on Apple platforms guarantees that a CFArray always
    // bridges to NSArray successfully, so a separate CFArray fallback path is
    // unreachable and has been removed.
    guard let nsArr = value as? NSArray else { return [] }

    var results: [SwWindow] = []
    results.reserveCapacity(nsArr.count)
    for i in 0..<nsArr.count {
        let item = nsArr.object(at: i)
        let cf = item as CFTypeRef
        if CFGetTypeID(cf) == AXUIElementGetTypeID() {
            results.append(SwWindow(element: item as! AXUIElement)) } }
    return results
}

// Performs a fresh, direct AX query for a PID's current windows, bypassing SWLState's
// cached snapshot entirely. SWLState's cached count is only ever as current as the last
// notification or diff that updated it, and — particularly for windows on another Space,
// which is a known area of AX unreliability — a single cached read can be transiently
// wrong. Callers making a destructive, hard-to-reverse decision (such as quitting an
// application) based on "zero windows" should re-verify against AX directly at the moment
// of that decision rather than trust a value that may have been set some time earlier.
// Returns nil if the fetch does not complete within the timeout or AX answers with an
// error (see fetchAXWindows); callers should treat nil conservatively (i.e., do not
// proceed with a destructive action) since no definitive answer was obtained.
public func liveWindowSnapshot(for pid: pid_t, timeoutNanos: UInt64 = 2 * 1_000_000_000) async -> [SwWindow]? {
    return await withCheckedContinuation { continuation in
        let race = SnapshotRace(continuation)
        // Both racers are DETACHED tasks rather than children of a task group.
        //
        // The previous implementation used withTaskGroup and a 'for await value in group'
        // loop that skipped any nil result — but nil is precisely what the timeout child
        // returned, so the loop discarded the timeout and went on to await the fetch. The
        // timeout had no effect whatsoever and the documented "aborting quit as a
        // precaution" path in ApplicationQuitter was unreachable.
        //
        // A task group cannot fix that on its own either: withTaskGroup does not return
        // until every child has finished, and fetchAXWindows blocks in a synchronous
        // AXUIElementCopyAttributeValue that cancellation cannot interrupt — so a hung AX
        // read would hold the group past the deadline no matter which racer "won". A
        // detached task is nobody's child, so a hung read is simply abandoned here and
        // completes into a discarded result.
        //
        // The timeout is armed BEFORE the fetch starts, so that a fetch which returns
        // immediately always finds a task to cancel. Without the cancellation the sleep
        // would run out its full two seconds after every single snapshot, and window
        // focus changes produce these in bursts.
        race.armTimeout(Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: timeoutNanos)
            race.finish(nil) })
        Task.detached(priority: .userInitiated) {
            do {
                race.finish(try fetchAXWindows(for: pid, timeoutNanos: timeoutNanos))
            } catch {
                log("(\(pid)) kAXWindowsAttribute read failed: \(error) — reporting snapshot as unavailable")
                race.finish(nil) } }
    }
}

// One-shot resume guard for liveWindowSnapshot's continuation. Whichever racer arrives
// first wins and the loser's resume is dropped — resuming a CheckedContinuation twice is
// a runtime trap, so the check cannot be left to chance. The lock is held only around the
// pointer swap, never across the resume itself. The state lives in a Mutex, so the
// Sendable conformance is checked by the compiler rather than asserted.
private final class SnapshotRace: Sendable {
    private struct State {
        var continuation: CheckedContinuation<[SwWindow]?, Never>?
        var timeout: Task<Void, Never>?
    }
    private let state: Mutex<State>

    init(_ continuation: CheckedContinuation<[SwWindow]?, Never>) {
        self.state = Mutex(State(continuation: continuation)) }

    func armTimeout(_ task: Task<Void, Never>) {
        // A race that has already been decided arms nothing; cancel the newcomer instead.
        let decided = state.withLock { s -> Bool in
            let decided = s.continuation == nil
            if !decided { s.timeout = task }
            return decided }
        if decided { task.cancel() } }

    /// Resolves the race. Only the first caller wins; every later one is discarded, which
    /// is what keeps the CheckedContinuation from being resumed twice (a runtime trap).
    func finish(_ value: [SwWindow]?) {
        let (pending, pendingTimeout) = state.withLock { s in
            defer { s.continuation = nil; s.timeout = nil }
            return (s.continuation, s.timeout) }
        // Canceled outside the lock, and only when this call actually won the race, so
        // the timeout's own finish() can never deadlock against the lock it is inside.
        if pending != nil { pendingTimeout?.cancel() }
        pending?.resume(returning: value) }
}

// Removed over successive passes, all unreferenced: BundleIdentifierForPID(_:) (it
// repeated the NSRunningApplication lookup registerAppForMonitoring already makes),
// isProcessRunning(pid:),
// AXObserverWrapper.debugPreviousCount(), the unreachable CFArray fallback in
// fetchAXWindows (toll-free bridging makes it dead on Apple platforms),
// runningAppNameForPID(_:) and the SwApp.localizedName it fed, and
// WindowDestroyedEvent.external, which was always true and never read.
