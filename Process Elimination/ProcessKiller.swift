// MARK: – ProcessKiller.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Responsible for detecting and force-killing unwanted processes by PID.

import Foundation
import Cocoa
import Darwin
import Synchronization

// `final` is required so the compiler can verify the class is not subclassed.
// ProcessKiller is captured with [weak self] inside @Sendable DispatchQueue and
// DispatchSourceTimer closures, so it must be Sendable. All mutable state lives in
// `state`, a Mutex, so the conformance is checked by the compiler rather than asserted.
// The work itself is still serialized on `timerQueue`; the lock is therefore never
// contended and exists to make that confinement provable, not to add concurrency.
final class ProcessKiller: Loggable, Sendable {
    static let logTag = "[ProcessKiller]"

    // Serial queue that owns timer lifecycle operations
    private let timerQueue = DispatchQueue(label: "com.processKiller.timerQueue", qos: .utility)
    // PIDs whose SIGKILL was refused with EPERM — a process owned by another user (root
    // XPC services are the common case), which this unprivileged process can never
    // signal. Each is still attempted on every sweep, so behavior is unchanged if that
    // ever ceases to be true, but the refusal is logged once per PID rather than on every
    // tick, and no retry is scheduled for it: a permission that was missing a moment ago
    // will not have appeared half a second later. Pruned on every sweep to whatever the
    // current match set contains, so a recycled PID is treated afresh. Accessed only on
    // timerQueue, like the rest of the mutable state here.
    private struct State {
        // DispatchSource timer (owned and managed on `timerQueue`)
        var processKillTimer: (any DispatchSourceTimer)?
        // Track the last started interval in seconds (DispatchSourceTimer doesn't expose this)
        var storedIntervalSeconds: Int?
        var permissionDeniedPIDs: Set<Int> = []
    }
    private let state = Mutex(State())

    // MARK: – Initialization
    init() {
        // Log the currently resolved blacklist size for diagnostics
        log("init() — resolved process blacklist contains \(Preferences.blacklistedProcesses.count) entries.")
        // Start timer according to current preferences (safe, idempotent)
        refreshFromPreferences() }

    // Cancels the timer directly rather than via stopTimerImmediately().
    //
    // That method does timerQueue.sync { [weak self] in self?.cancelTimer() }, which is
    // wrong on both counts inside deinit. First, by the time deinit runs every weak
    // reference to self is already nil, so the closure did nothing and the timer source
    // was never canceled — it kept firing into a nil weak self and, because an
    // un-canceled dispatch source is retained by its own registration, leaked. Second,
    // the last strong reference can be dropped from a timerQueue block: the timer's event
    // handler and refreshFromPreferences() both hold self strongly for the duration of
    // their block, so if AppDelegate sets pk = nil while a sweep is running, this deinit
    // executes ON timerQueue — and dispatch_sync onto the serial queue one is already on
    // deadlocks. Toggling the process killer off while a sweep happens to be in progress
    // was enough to hang the application.
    //
    // Reading processKillTimer here without the queue is safe: deinit runs only when
    // no strong reference remains, so no timerQueue block can be executing against self
    // (each holds a strong reference while it runs), and any block still queued captured
    // self weakly and will find nil. DispatchSourceTimer.cancel() itself is thread-safe.
    deinit {
        if let timer = state.withLock({ $0.processKillTimer }) {
            timer.setEventHandler {}
            timer.cancel() } }

    // MARK: – Process killer
    // Force-kill all blacklisted processes.
    func killBlacklistedProcesses() {
        guard Preferences.killBlacklistedProcessesEnabled else {
            log("Process killer disabled by preference."); return }

        // Always read the canonical blacklist at time of action. System-critical names are
        // dropped here too: the settings UI refuses them, but the list can also be written
        // directly to the defaults domain, and SIGKILLing e.g. loginwindow logs the user out.
        let blacklist = Preferences.blacklistedProcesses.filter {
            !InputValidation.isProcessWhitelisted($0) }
        if blacklist.isEmpty { log("Blacklist is empty — nothing to do."); return }

        // One pgrep invocation for the entire blacklist, not one per entry.
        let matches: [(pid: Int, name: String)]
        do {
            matches = try fetchMatchingProcesses(for: blacklist)
        } catch {
            log("ERROR: Unable to enumerate processes: \(error.localizedDescription)")
            return }
        if matches.isEmpty { state.withLock { $0.permissionDeniedPIDs.removeAll() }; return } // Nothing blacklisted is currently running.
        state.withLock { $0.permissionDeniedPIDs.formIntersection(matches.map { $0.pid }) }

        for (pid, processName) in matches {
            // Never signal this process itself. pgrep excludes only its own PID, so an
            // entry naming this application's executable (typed in, or written to the
            // defaults domain) would otherwise SIGKILL it on every launch, one interval in.
            if pid == Int(getpid()) { continue }
            let previouslyDenied = state.withLock { $0.permissionDeniedPIDs.contains(pid) }
            if !previouslyDenied { log("Killing process '\(processName)' (PID \(pid))") }
            // kill() returns 0 on success.
            if kill(pid_t(pid), SIGKILL) != 0 {
                // Capture errno immediately — any subsequent Swift runtime
                // call, even a string interpolation, may overwrite it.
                let capturedErrno = errno
                if capturedErrno == EPERM {
                    if !previouslyDenied {
                        state.withLock { _ = $0.permissionDeniedPIDs.insert(pid) }
                        log("Not permitted to kill PID \(pid) for process '\(processName)' (EPERM — owned by another user). Will keep trying silently.")
                    }
                    continue
                }
                // ESRCH ("no such process") means the target already exited in
                // the gap between the pgrep snapshot and this kill() call. That
                // is precisely the desired end state, so treat it as success
                // rather than scheduling a retry that would only fail again with
                // ESRCH 0.5 s later and emit a misleading error in the log.
                if capturedErrno == ESRCH {
                    log("Process '\(processName)' (PID \(pid)) already exited before SIGKILL (ESRCH) — treating as success.")
                    continue
                }
                log("Failed to kill PID \(pid) for process '\(processName)'. Errno: \(capturedErrno). Retrying...")
                // Retry asynchronously after 0.5 seconds.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    if kill(pid_t(pid), SIGKILL) != 0 {
                        let err2 = errno
                        // ESRCH on the retry likewise means the process is now
                        // gone — the intended outcome, not a failure.
                        if err2 == ESRCH {
                            self.log("Process '\(processName)' (PID \(pid)) exited before the retry SIGKILL (ESRCH) — treating as success.")
                        } else {
                            self.log("ERROR: Second attempt to kill PID \(pid) for process '\(processName)' also failed. Errno: \(err2).")
                        }
                    } else { self.log("Succeeded on second attempt to kill PID \(pid).") } }
            } else {
                state.withLock { _ = $0.permissionDeniedPIDs.remove(pid) }
                log("Successfully killed PID \(pid) for process '\(processName)'.") } } }

    // MARK: – Get PIDs for blacklisted processes
    // Runs `pgrep` ONCE for the whole blacklist and returns every match.
    //
    // This used to be one `pgrep -x <name>` per blacklist entry, on every tick: with the
    // nine built-in entries and the default five-second interval, roughly two process
    // spawns per second for the entire lifetime of the app, each with two pipes and a
    // waitUntilExit. `-x` anchors the pattern to the whole process name, so a single
    // alternation of the entries matches exactly the same set of processes in one fork.
    // It also shortens the timerQueue.sync that stopTimerImmediately() performs on the
    // main thread during termination, which previously had to wait out a whole sweep.
    //
    // The escaping is a fix in its own right: these names were being handed to pgrep as
    // raw extended regular expressions, so an entry such as
    // "com.apple.CloudPhotosConfiguration" had every '.' acting as a wildcard and could
    // match a same-length name it was never meant to. The Process List tab calls these
    // "exact executable name", so they are now matched as literals.
    // A note on names: pgrep MATCHES against the process's full name (an entry longer
    // than 15 characters, such as "AvatarPickerMemojiPicker", matches correctly), but the
    // name `-l` PRINTS is truncated to the 15-character accounting name — "endpointsecurit"
    // for endpointsecurityd. Logging that truncated string would be a regression against
    // the per-entry version, which always had the full name to hand, so each reported name
    // is mapped back to the blacklist entry it is a prefix of. Only the log line depends on
    // this; the matching itself is entirely pgrep's.
    //   - Parameter blacklist: The exact process names to search for.
    //   - Returns: The (pid, name) pair for every running process matching an entry.
    private func fetchMatchingProcesses(
        for blacklist: [String]) throws -> [(pid: Int, name: String)] {
        let pattern = blacklist.map(Self.regexEscaped).joined(separator: "|")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // -x: the pattern must match the whole name, not a substring.
        // -l: print "<pid> <name>", so the matched name is available for the log without
        //     a second lookup per PID.
        task.arguments = ["-x", "-l", pattern]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        // Assigning a Pipe to standardError prevents stderr from inheriting the
        // parent's fd and potentially blocking the child. The read end is explicitly
        // closed after the process exits so the OS file descriptor is released
        // immediately rather than waiting for ARC to deallocate the Pipe object.
        task.standardError = stderrPipe

        try task.run()

        // Read stdout BEFORE calling waitUntilExit(). If the child produces more
        // output than the pipe's internal buffer can hold (~64 KB on macOS), and we
        // wait first, the child blocks trying to write while we block waiting for it
        // to exit — a classic deadlock. Reading first drains the pipe and lets the
        // child finish naturally.
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        // Release the stderr pipe's read-end file descriptor promptly. The Pipe
        // retains the fd until it is deallocated; closing it here ensures the OS
        // resource is freed on this run-loop turn rather than whenever ARC decides
        // to deallocate the local stderrPipe variable.
        stderrPipe.fileHandleForReading.closeFile()

        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else { return [] }

        // pgrep exits non-zero when nothing matches, which is an ordinary outcome here and
        // produces no output — so the exit status is deliberately not consulted.
        return output
            .split(separator: "\n")
            .compactMap { line -> (pid: Int, name: String)? in
                // Each line is "<pid> <name>". The name may itself contain spaces, so the
                // split is on the FIRST space only.
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separator = trimmed.firstIndex(of: " ") else {
                    log("Unexpected pgrep output line (no name field): '\(trimmed)'")
                    return nil }
                guard let pid = Int(trimmed[trimmed.startIndex..<separator]) else {
                    log("Unexpected, non-integer PID output from pgrep: '\(trimmed)'")
                    return nil }
                let reported = trimmed[trimmed.index(after: separator)...]
                    .trimmingCharacters(in: .whitespaces)
                // Recover the untruncated name from the blacklist entry that produced this
                // match. An exact hit wins outright; otherwise the entry this reported name
                // is a prefix of is the one pgrep matched. Falling back to the reported
                // name covers the only ambiguous case — two entries sharing their first 15
                // characters — with a truncated but still accurate label.
                let name = blacklist.first { $0 == reported }
                    ?? blacklist.first { $0.hasPrefix(reported) }
                    ?? reported
                return (pid: pid, name: name) } }

    // Escapes every POSIX extended-regular-expression metacharacter, so a blacklist entry
    // is matched as the literal string the user typed rather than as a pattern.
    private static func regexEscaped(_ name: String) -> String {
        let metacharacters: Set<Character> = ["\\", "^", "$", ".", "[", "]", "|",
                                              "(", ")", "*", "+", "?", "{", "}"]
        var out = ""
        out.reserveCapacity(name.count)
        for character in name {
            if metacharacters.contains(character) { out.append("\\") }
            out.append(character) }
        return out }

    // MARK: – Timer management
    // Public wrapper to stop timer (async, safe)
    func stopTimer() { timerQueue.async { [weak self] in self?.cancelTimer() } }

    // Synchronous immediate stop (used by deinit() to ensure cancelation before exit)
    func stopTimerImmediately() { timerQueue.sync { [weak self] in self?.cancelTimer() } }

    // Centralized timer cancelation. Must only be called while already executing
    // on timerQueue (either from within a timerQueue.async block or timerQueue.sync).
    private func cancelTimer() {
        let current = state.withLock { s -> (any DispatchSourceTimer)? in
            let timer = s.processKillTimer
            s.processKillTimer = nil
            s.storedIntervalSeconds = nil
            return timer }
        guard let timer = current else { return }
        timer.setEventHandler {}
        timer.cancel()
        log("Timer canceled.") }

    // MARK: – Refresh the timer according to current Preferences:
    //   - If disabled, stops the timer.
    //   - If enabled and timer not running, starts it.
    //   - If enabled and interval changed, restarts with the new interval.
    // Called exclusively by AppDelegate in response to preference changes; ProcessKiller
    // does not observe the preferences-changed notification itself.
    func refreshFromPreferences() {
        timerQueue.async { [weak self] in
            guard let self = self else { return }
            let enabled = Preferences.killBlacklistedProcessesEnabled
            if !enabled {
                // Preference disabled -> cancel immediately (we are already on timerQueue).
                self.cancelTimer() // No-op when no timer is running.
                return }

            // Enabled -> ensure timer is running with the current interval.
            let desiredInterval = min(max(1, Preferences.processKillIntervalSeconds), 3600)

            if let running = self.state.withLock({ $0.storedIntervalSeconds }) {
                guard running != desiredInterval else { return } // Same interval — nothing to do.
                // Interval changed: cancel the current timer, then start a new one inline.
                // We are already executing on timerQueue, so both cancelTimer() and the
                // timer-start logic below run sequentially on the same queue — no extra
                // async hop is needed.
                self.cancelTimer()
            }

            // Start (or restart) the timer inline on timerQueue.
            let leewayMs = max(500, Int(TimeInterval(desiredInterval) * 1000.0 / 10.0))
            let timer = DispatchSource.makeTimerSource(queue: self.timerQueue)
            timer.schedule(deadline: .now() + TimeInterval(desiredInterval),
                           repeating: TimeInterval(desiredInterval),
                           leeway: .milliseconds(leewayMs))
            timer.setEventHandler { [weak self] in self?.killBlacklistedProcesses() }
            self.state.withLock {
                $0.processKillTimer = timer
                $0.storedIntervalSeconds = desiredInterval }
            timer.resume()
            self.log("Timer started with interval \(desiredInterval) seconds.") } }
}
