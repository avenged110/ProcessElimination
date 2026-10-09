// MARK: – GlobalUtilities.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Shared utility types and validation logic for Process Elimination.app.
// Consolidates the previously separate Utilities.swift and InputValidation.swift.
// (SymbolCache previously lived here too; removed — analysis showed it never
// produced a caching benefit given StatusMenuController's own titleCache, so
// its call sites were switched to build SF Symbol images directly.)

import Cocoa
import UniformTypeIdentifiers

// MARK: – OpenPanelConfiguration
// Value type that carries all configuration for a single NSOpenPanel presentation.
// Pass an instance to OpenPanelPresenter.present(configuration:attachedTo:) rather
// than constructing and configuring an NSOpenPanel directly at each call site.
@MainActor
struct OpenPanelConfiguration {
    var canChooseFiles: Bool = true
    var canChooseDirectories: Bool = false
    var allowsMultipleSelection: Bool = false
    var allowedContentTypes: [UTType] = []

    var title: String?
    var message: String?
    var prompt: String?

    // Initial directory shown when the panel opens.
    // If nil, defaults to /Applications (the most relevant starting point for this app).
    var directoryURL: URL?

    init(
        canChooseFiles: Bool = true,
        canChooseDirectories: Bool = false,
        allowsMultipleSelection: Bool = false,
        allowedContentTypes: [UTType] = [],
        title: String? = nil,
        message: String? = nil,
        prompt: String? = nil,
        directoryURL: URL? = nil) {
        self.canChooseFiles = canChooseFiles
        self.canChooseDirectories = canChooseDirectories
        self.allowsMultipleSelection = allowsMultipleSelection
        self.allowedContentTypes = allowedContentTypes
        self.title = title
        self.message = message
        self.prompt = prompt
        self.directoryURL = directoryURL
    }
}

// MARK: – OpenPanelSelection
// Typed result returned by OpenPanelPresenter. Avoids the caller having to inspect
// a bare optional — .canceled is unambiguous regardless of how many URLs were chosen.
@MainActor
enum OpenPanelSelection {
    case canceled
    case urls([URL])
}

// MARK: – OpenPanelPresenter
// Centralized helper for presenting NSOpenPanel as a sheet (or app-modal fallback)
// with consistent sizing and a fixed, non-resizable panel style.
@MainActor
enum OpenPanelPresenter {

    // Presents an NSOpenPanel configured with the provided options and returns the
    // user's selection asynchronously.
    //
    // - Parameters:
    //   - configuration: Configuration options for the panel.
    //   - window: The window to attach the sheet to. If nil, uses keyWindow, then
    //             mainWindow, then falls back to an app-modal panel.
    // - Returns: '.urls([URL])' if the user confirmed, '.canceled' otherwise.
    static func present(
        configuration: OpenPanelConfiguration,
        attachedTo window: NSWindow? = nil
    ) async -> OpenPanelSelection {
        let panel = NSOpenPanel()

        // Core configuration.
        panel.canChooseFiles          = configuration.canChooseFiles
        panel.canChooseDirectories    = configuration.canChooseDirectories
        panel.allowsMultipleSelection = configuration.allowsMultipleSelection

        if !configuration.allowedContentTypes.isEmpty {
            panel.allowedContentTypes = configuration.allowedContentTypes
        }

        // Default to /Applications when no directory is specified — the most relevant
        // starting point when browsing for .app bundles in this project.
        if let directoryURL = configuration.directoryURL {
            panel.directoryURL = directoryURL
        } else {
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
        }

        if let title   = configuration.title   { panel.title   = title   }
        if let message = configuration.message { panel.message = message }
        if let prompt  = configuration.prompt  { panel.prompt  = prompt  }

        // Enforce fixed size and non-resizable behavior.
        panel.styleMask.remove(.resizable)
        panel.setContentSize(NSSize(width: 600, height: 400))
        panel.isMovable = false

        let targetWindow = window ?? NSApp.keyWindow ?? NSApp.mainWindow

        return await withCheckedContinuation { continuation in
            if let targetWindow {
                // Present as a sheet attached to the window.
                panel.beginSheetModal(for: targetWindow) { response in
                    if response == .OK {
                        continuation.resume(returning: .urls(panel.urls))
                    } else {
                        continuation.resume(returning: .canceled)
                    }
                }
            } else {
                // Fallback: app-modal (should rarely happen in normal use).
                panel.begin { response in
                    if response == .OK {
                        continuation.resume(returning: .urls(panel.urls))
                    } else {
                        continuation.resume(returning: .canceled)
                    }
                }
            }
        }
    }
}

// MARK: – InputValidation
// Validation logic for all input fields in Process Elimination.app's settings window.
enum InputValidation {

    // MARK: – Whitelists
    // Declared as static constants so the sets are allocated once, not per call.

    // System-critical process names that may never be added to the process blacklist.
    private static let processWhitelist: Set<String> = [
        "configd", "coreservicesd", "distnoted", "Finder", "hidd",
        "kernel_task", "launchd", "loginwindow", "mDNSResponder",
        "opendirectoryd", "powerd", "securityd", "UserEventAgent", "WindowServer"
    ]

    // System-critical application bundle IDs that may never be added to the app blacklist.
    private static let applicationBundleIDWhitelist: Set<String> = [
        "com.apple.finder"  // Finder
    ]

    // True for a system-critical process name (case-insensitive). Also consulted by
    // ProcessKiller at kill time, so a whitelisted name written to the defaults domain
    // directly — bypassing this UI validation — is still never signaled.
    static func isProcessWhitelisted(_ name: String) -> Bool {
        processWhitelist.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: – Alert presentation
    // Presents a validation alert sheet anchored to the window that owns 'tf' (or 'view').
    // Always runs on the main thread; every call site arrives from an AppKit delegate
    // callback, which is always main-thread. The window-resolution chain matches the
    // previous implementation: tf.window → view.window → keyWindow → mainWindow.
    @MainActor
    private static func presentValidationAlert(
        revertValue: String,
        forField tf: NSTextField,
        in view: NSView,
        message: String
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        let attachWindow = unsafe tf.window ?? view.window ?? NSApp.keyWindow ?? NSApp.mainWindow

        if let window = attachWindow {
            alert.beginSheetModal(for: window) { _ in
                tf.stringValue = revertValue
                window.makeFirstResponder(tf)
            }
        } else {
            // No window available — revert the field value immediately.
            tf.stringValue = revertValue
        }
    }

    // Simpler alert variant used when there is no text field to revert — only a
    // message and an optional target window are required. Internal (not private)
    // so tab views can use it directly without duplicating the NSAlert pattern.
    @MainActor
    static func presentWarningAlert(message: String, in view: NSView) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        if let window = unsafe view.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

    // MARK: – Integer field validator
    // Validates a numeric NSTextField whose value must be a whole number in [min, max].
    // The field is expected to have a WholeIntegerFormatter attached, so by the time
    // this method is called the string is guaranteed to contain only digits (or be
    // empty). Persists via 'setNew' only when the value differs from 'getCurrent()'.
    //
    // Parameters:
    //   sender       – The NSTextField that finished editing.
    //   min / max    – Inclusive integer bounds.
    //   getCurrent   – Returns the currently persisted value (avoids a redundant write).
    //   setNew       – Persists the validated value (should call a Preferences setter).
    //   revertValue  – Text to display when input is empty or out of bounds.
    //   errorMessage – Alert message shown when the value is outside [min, max].
    //   view         – Used to locate the sheet-attachment window.
    @MainActor
    static func validateIntegerField(
        _ sender: NSTextField,
        min: Int,
        max: Int,
        getCurrent: () -> Int,
        setNew: (Int) -> Void,
        revertValue: String,
        errorMessage: String,
        in view: NSView
    ) {
        let raw = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty input — restore previous visible string without writing anything.
        guard !raw.isEmpty else {
            sender.stringValue = revertValue
            return
        }

        // WholeIntegerFormatter ensures only digits reach this point, so Int(raw)
        // will succeed unless the value overflows Int (not a realistic concern here).
        guard let entered = Int(raw), entered >= min && entered <= max else {
            presentValidationAlert(revertValue: revertValue, forField: sender,
                                   in: view, message: errorMessage)
            return
        }

        // Persist only if the value actually changed.
        if entered != getCurrent() {
            setNew(entered)
        }

        sender.stringValue = "\(entered)"
    }

    // MARK: – Process name validator
    // Validates a proposed process name entry. Rejects system-whitelisted names and
    // exact duplicates (case-insensitive) of any other entry in 'currentList'.
    //
    // The caller must pass the actual on-screen NSTextField as 'sender' so that alert
    // revert and focus-restoration target the visible field, not a detached proxy.
    //
    // Returns 'true' if the value is valid and should be committed; 'false' otherwise.
    // On failure the alert handles revert and focus-restoration internally, so the
    // caller only needs to act on the return value.
    @MainActor
    static func validateProcessNameField(
        _ sender: NSTextField,
        atRow row: Int,
        currentList: [String],
        priorValue: String,
        in view: NSView
    ) -> Bool {
        let raw = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty trimmed value — caller decides whether to remove the row.
        guard !raw.isEmpty else { return false }

        // Reject whitelisted system process names.
        if isProcessWhitelisted(raw)
            || raw.caseInsensitiveCompare(ProcessInfo.processInfo.processName) == .orderedSame {
            presentValidationAlert(
                revertValue: priorValue, forField: sender, in: view,
                message: "\"\(raw)\" is whitelisted for system stability and cannot be added.")
            return false
        }

        // Reject duplicates (exclude the row currently being edited).
        var others = currentList
        if others.indices.contains(row) { others.remove(at: row) }

        let isDuplicate = others.contains {
            $0.caseInsensitiveCompare(raw) == .orderedSame
        }
        if isDuplicate {
            presentValidationAlert(
                revertValue: priorValue, forField: sender, in: view,
                message: "\"\(raw)\" already exists in the process blacklist.")
            return false
        }

        return true
    }

    // MARK: – Application blacklist validator
    // Validates a proposed BlacklistedApplication entry. Rejects entries whose
    // bundle ID matches a system-whitelisted application and rejects bundle ID
    // duplicates against every other entry in 'currentList'.
    //
    // Duplicate detection uses bundle ID (the true identity key) rather than display
    // name, preventing two entries with the same bundle ID from coexisting regardless
    // of how their display names differ.
    //
    // Returns 'true' if valid and should be committed; 'false' otherwise. On failure
    // the alert handles revert and focus-restoration internally.
    @MainActor
    static func validateApplicationEntry(
        bundleID: String,
        displayName: String,
        currentList: [BlacklistedApplication],
        in view: NSView
    ) -> Bool {
        // Reject whitelisted bundle IDs (case-insensitive).
        let isWhitelisted = applicationBundleIDWhitelist.contains {
            $0.caseInsensitiveCompare(bundleID) == .orderedSame
        }
        if isWhitelisted {
            let name = displayName.isEmpty ? bundleID : displayName
            presentWarningAlert(
                message: "\"\(name)\" is whitelisted for system stability and cannot be added.",
                in: view)
            return false
        }

        // Reject duplicate bundle IDs.
        let isDuplicate = currentList.contains {
            $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame
        }
        if isDuplicate {
            let name = displayName.isEmpty ? bundleID : displayName
            presentWarningAlert(
                message: "\"\(name)\" already exists in the application blacklist.",
                in: view)
            return false
        }

        return true
    }
}

// MARK: – WholeIntegerFormatter
// NSFormatter subclass used as the formatter on the process-kill interval NSTextField.
// isPartialStringValid is AppKit's authoritative pre-storage intercept: it fires before
// any proposed change reaches text storage regardless of input method (typing, paste,
// drag-drop, IME, etc.). Stripping every non-digit character here means the field
// silently accepts only whole integers — no period, no minus sign, no letters.
//
// maxDigits caps the raw digit count so that values that would exceed 3600 (the upper
// bound enforced at commit time) are truncated at the source rather than letting
// validateIntegerField's out-of-range path fire after a multi-digit overflow.
// Four digits (9999) is a generous but safe ceiling: it allows any value 1–3600 while
// blocking inputs that would obviously be rejected.
final class WholeIntegerFormatter: Formatter {

    // Maximum digit count accepted by the field. Set to 4 so users can type any
    // value in the legal range (1–3600) without premature truncation, while still
    // blocking obviously out-of-range multi-digit overflows before commit time.
    private let maxDigits: Int

    init(maxDigits: Int = 4) {
        self.maxDigits = maxDigits
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    // Identity conversions — the "object value" is the raw string itself.
    override func string(for obj: Any?) -> String? { obj as? String }

    override func getObjectValue(
        _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
        for string: String,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        unsafe obj?.pointee = string as AnyObject
        return true
    }

    /// Strip non-digits and truncate to maxDigits before the change reaches storage.
    /// Returning true  = accept the proposed string as-is.
    /// Returning false = silently apply the modified partialStringPtr instead.
    override func isPartialStringValid(
        _ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
        proposedSelectedRange proposedSelRangePtr: NSRangePointer?,
        originalString origString: String,
        originalSelectedRange origSelRange: NSRange,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        let proposed = unsafe partialStringPtr.pointee as String
        // Keep only ASCII digit characters and cap to maxDigits.
        //
        // The isASCII test is load-bearing: Character.isNumber alone is true for
        // Arabic-Indic digits, superscripts and vulgar fractions ("٣", "²", "½"), which
        // would pass this filter, reach validateIntegerField, fail Int(raw), and be
        // reported to the user as an out-of-range error for a value that was never a
        // number at all.
        let filtered = String(
            proposed.filter { $0.isASCII && $0.isNumber }.prefix(maxDigits))

        // Proposed string is already clean — accept without touching anything.
        if filtered == proposed { return true }

        // Apply the cleaned string and clamp the cursor to the new length.
        unsafe partialStringPtr.pointee = filtered as NSString
        if let ptr = unsafe proposedSelRangePtr {
            unsafe ptr.pointee = NSRange(
                location: min(ptr.pointee.location, filtered.count), length: 0)
        }
        return false
    }
}
