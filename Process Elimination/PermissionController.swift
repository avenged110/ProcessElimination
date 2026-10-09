// MARK: – PermissionController.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Handles so-called 'accessibility' permission prompts, TCC enforcement, and UI warnings.

import Cocoa
import ApplicationServices // For so-called 'accessibility' APIs

// @MainActor isolation is required because:
//   - All AppKit and Preferences mutations performed here must occur on the main thread.
//   - Every call site (AppDelegate, StatusMenuController) is already @MainActor,
//     so isolation is free — no additional dispatch hops are needed.
@MainActor
final class PermissionController: Loggable {
    nonisolated static let logTag = "[PermissionController]"

    // MARK: - Lifecycle
    // Attempt to trigger macOS to add the application to the permissions list in Settings.app.
    func triggerTCCSeed() {
        // Build the CF key by bridging a Swift string: avoids both Unmanaged<> (the
        // imported kAXTrustedCheckOptionPrompt) and raw C string pointers.
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options: CFDictionary = [promptKey: kCFBooleanTrue] as CFDictionary
        // Ask the system to present guidance; It may or may not display a dialog.
        _ = AXIsProcessTrustedWithOptions(options)
        log("triggerTCCSeed() – Called AXIsProcessTrustedWithOptions(...)")
        // Reflect whatever TCC state we now have in the persisted preferences.
        enforceAQPermissionsState() }

    // Returns whether Accessibility permission is currently granted.
    // Intentionally does not log: this function is called from several hot paths
    // (enforceAQPermissionsState, SettingsViewModel.refreshAQState, the menu's
    // elements closure, computed properties in STabAQ) and logging on every
    // invocation produces excessive noise.
    static func aqAccessGranted() -> Bool {
        return AXIsProcessTrusted() }

    // MARK: - Enforcement
    // Reconciles the persisted AQ preference with the current TCC Accessibility grant.
    // The menu no longer holds live NSMenuItem references — it is rebuilt on every open
    // and reads Preferences plus aqAccessGranted() as it builds — so this method only
    // has to keep the *preference* honest: force the toggle off (saving the user's
    // choice) while permission is denied, and restore that choice once it is granted.
    // Called from the menu's willOpen hook and from triggerTCCSeed().
    func enforceAQPermissionsState() {
        if Self.aqAccessGranted() {
            // Permission granted -> restore the user's saved preference if it was
            // previously forced off due to a TCC denial.
            if Preferences.aqWasForced {
                Preferences.restoreAQPreForcedState()
                Self.log("TCC permission restored — restoring user preference") }
        } else {
            // Permission denied -> save the user's current preference once, then force
            // the toggle off so AQ cannot operate without the required TCC grant.
            if !Preferences.aqWasForced {
                Preferences.saveAQPreForcedState()
                Self.log("TCC permission denied — saving user preference and forcing off toggle") }

            // Explicitly write false to the persisted preference so it matches the
            // forced-off state. This is necessary for the TCC-grant recovery path:
            // when permission is later granted, restoreAQPreForcedState() writes the
            // saved (pre-denial) value back. If that saved value was 'true' and the
            // current stored value is also 'true' (because saveAQPreForcedState never
            // set it to false), setIfChanged detects no change, no notification is
            // posted, and AppDelegate never creates a new ApplicationQuitter instance.
            // Writing false here ensures a real change is detected on restoration so
            // the notification fires and AppDelegate initializes AQ correctly.
            Preferences.quitBlacklistedApplicationsEnabled = false } }

    // Show a modal explaining how to grant so-called 'Accessibility' access.
    // Uses runModal (app-modal) because this is invoked from a menu action on the
    // main thread and no key window is guaranteed to be available as a sheet target.
    // NSApp.activate is deliberately omitted: this app runs at .accessory policy and
    // must never activate itself (no Dock icon, no menu bar takeover).
    @MainActor
    static func showPermissionAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = """
        Process Elimination cannot reliably quit applications without being granted "Accessibility" permissions.

        This must be done manually.

        You must first grant permission in
        System Settings → Privacy & Security.
        """
        alert.addButton(withTitle: "Open Settings") // Index 0
        alert.addButton(withTitle: "Cancel")        // Index 1

        let response = alert.runModal()

        // Open Settings.app → Privacy & Security → 'Accessibility'
        if response == .alertFirstButtonReturn {
            let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url) } }
}
