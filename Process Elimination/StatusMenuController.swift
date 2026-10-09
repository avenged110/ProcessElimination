// MARK: – StatusMenuController.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Process Elimination.app's menu-bar applet: the status item, its menu, and the
// Settings window.
//
// This is the project-specific half of what StatusMenuController.swift used to be. The
// chrome — status item, menu construction, attributed titles, symbol caching, synchronous
// teardown — now lives in the shared MenuControlKit.swift, and the Settings window in the
// shared SettingsKit.swift. What remains here is only what is actually Process
// Elimination's: which rows the menu carries, which preferences they bind to, the
// Accessibility permission gate in front of the App Quitter row, and what the Settings
// window contains.
//
// The app runs as `.accessory` for its whole lifetime — set once in AppDelegate and never
// changed, as in LAN Stream, Toggler and Ethernet Status.

import Cocoa
import SwiftUI

@MainActor
final class StatusMenuController: NSObject, Loggable {
    nonisolated static let logTag = "[SMC]"

    // Injected controller.
    private let permCon: PermissionController

    // State hub threaded into every settings tab.
    private let settingsViewModel = SettingsViewModel()

    // MARK: – Settings window
    //
    // Built once, lazily, and held for the app's lifetime; SettingsWindowController
    // itself builds the NSWindow on first open and discards it on close, so holding this
    // costs one small object rather than a live window. `_settings` staying nil is also
    // how the termination path can ask "is a Settings window up?" without *building* the
    // controller in order to find out.
    private var _settings: SettingsWindowController?
    private var settings: SettingsWindowController {
        if let existing = _settings { return existing }
        let created = makeSettingsController()
        _settings = created
        return created
    }

    private func makeSettingsController() -> SettingsWindowController {
        // Captured as a local `let` so the tab-builder closures below close over the
        // view model directly rather than over `self`.
        let vm = settingsViewModel
        return SettingsWindowController(.init(
            title: "Process Elimination Settings",
            sizing: .fitToContent(width: SettingsLayout.contentWidth,
                                  minimumHeight: SettingsLayout.minimumContentHeight),
            tabs: [
                .swiftUI(id: "general", title: "General", symbol: "gearshape") {
                    SettingsTabGeneralView(viewModel: vm)
                },
                .swiftUI(id: "processList", title: "Process List", symbol: "xmark.circle") {
                    SettingsTabPKView(viewModel: vm)
                },
                .swiftUI(id: "appQuitter", title: "App Quitter",
                         symbol: "macwindow.and.cursorarrow") {
                    SettingsTabAQView(viewModel: vm)
                },
            ],
            styleMask: [.titled, .closable, .miniaturizable],
            // LSUIElement app: without a temporary main menu the Settings window would
            // have no Cut/Copy/Paste and no ⌘W.
            installsTemporaryMainMenu: true,
            // Kept pointing at AppDelegate rather than left nil: the kit's nil branch
            // wires the item straight to orderFrontStandardAboutPanel but with no key
            // equivalent, and this preserves ⌘?.
            aboutMenuAction: #selector(AppDelegate.showAboutPanel(_:)),
            onTabSelected: { [weak self] id in
                // Only App Quitter has external state (the TCC Accessibility permission)
                // that needs a live refresh on tab switch.
                if id == "appQuitter" { self?.settingsViewModel.refreshAQState() }
            },
            onWindowDidBecomeKey: { [weak self] in
                self?.settingsViewModel.refreshAQState()
            }))
    }

    // MARK: – Status menu
    //
    // `elements` is re-evaluated on every menu open, so the checkmarks track the
    // preferences and the App Quitter warning glyph tracks the TCC grant with no
    // reconcile pass, no retained NSMenuItem references and no
    // updateMenuCheckmarksFromPreferences().
    //
    // [weak self] is captured once, here; the per-element closures inherit the unwrapped
    // reference rather than each capturing self strongly.
    private lazy var menu = MenuController(.init(
        appName: "Process Elimination",
        icon: { .symbol(.menuBar("xmark.circle", weight: .medium),
                        fallbackTitle: "ProcElm") },
        elements: { [weak self] in
            guard let self else { return [] }
            let aqGranted = PermissionController.aqAccessGranted()
            // The warning triangle appended to the App Quitter row while the TCC grant
            // is denied. Previously pushed in from PermissionController via
            // setMenuItem(_:title:symbolName:checked:); now computed on every open.
            let aqWarning: String? = aqGranted ? nil : "exclamationmark.triangle.fill"

            return [
                .toggle(id: "killPK", title: "Kill Blacklisted Processes", key: "p",
                        isOn: { Preferences.killBlacklistedProcessesEnabled },
                        setOn: { Preferences.killBlacklistedProcessesEnabled = $0 }),

                .action(id: "configPK", title: "Configure…", key: "c") {
                    self.openSettings(tab: "processList")
                },

                .separator,

                .toggle(id: "aq", title: "Application Quitter", key: "a",
                        symbolName: aqWarning,
                        isOn: { Preferences.quitBlacklistedApplicationsEnabled },
                        willChange: { newValue in !newValue || self.demandAccessibilityPermission() },
                        setOn: { Preferences.quitBlacklistedApplicationsEnabled = $0 }),

                // Option-only modifier mask, as before — not ⌘⌥. Disabled while the TCC
                // grant is denied, matching the old configItem.isEnabled = false path.
                .action(id: "configAQ", title: "Configure…", key: "c",
                        modifiers: [.option], isEnabled: aqGranted) {
                    self.openSettings(tab: "appQuitter")
                },

                .separator,

                .action(id: "settings", title: "Settings…", key: ",") {
                    self.openSettings()
                },

                .separator,

                .about(title: "About Process Elimination…") {
                    self.showAboutPanel()
                },

                .separator,

                .quit(title: "Quit Process Elimination"),
            ]
        },
        // Re-checked on every open, so a TCC grant changed in System Settings while the
        // app was running is reconciled into the persisted preference before the rows
        // this build produces are read.
        willOpen: { [weak self] in self?.permCon.enforceAQPermissionsState() }))

    // MARK: - Initialization
    init(permCon: PermissionController) {
        self.permCon = permCon
        super.init()
    }

    /// Installs the status item. Call once, at launch.
    func install() { menu.install() }

    // MARK: - Menu Actions

    /// Gate in front of the App Quitter row. Returning false vetoes the preference
    /// write, and the row visibly does not move.
    private func demandAccessibilityPermission() -> Bool {
        guard PermissionController.aqAccessGranted() else {
            PermissionController.showPermissionAlert()
            return false
        }
        return true
    }

    /// Opens the Settings window, optionally to a specific tab.
    ///
    /// The app stays `.accessory` throughout — no policy flip, no run-loop drain, no Dock
    /// tile appearing and disappearing around the window. `SettingsWindowController.open()`
    /// calls `NSApp.activate()`, which is what brings the window to the front from an
    /// accessory app, and the temporary main menu supplies the menu bar it needs while it
    /// is up.
    private func openSettings(tab id: String? = nil) {
        guard !isTerminating else {
            log("Skipping openSettings: the application is terminating.")
            return
        }
        settings.open(tab: id)
        log("Opening Settings window –> '\(id ?? "General")' tab.")
    }

    /// Shows the standard macOS about panel, which renders the app icon, name, version
    /// and the GPL-3.0 text from Credits.html in the bundle's Resources.
    ///
    /// As with the Settings window, the app stays `.accessory`; `NSApp.activate()` is what
    /// brings the panel to the front.
    func showAboutPanel() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
        log("Opening the standard About panel.")
    }

    // MARK: – Termination

    private var isTerminating = false

    /// Called by AppDelegate when termination starts, so no window is opened while the
    /// process is shutting down.
    func markTerminating() {
        isTerminating = true
        menu.markTerminating()
    }

    /// Synchronous teardown: closes the Settings window and pulls the status item before
    /// the process unwinds.
    func prepareForTerminationSynchronously() {
        isTerminating = true
        menu.markTerminating()
        // Short-circuits on `_settings` being nil so an app that never opened Settings
        // does not build the controller here just to discover it has no window.
        if let settings = _settings, settings.visibleWindow != nil {
            settings.close()
            // Give AppKit a brief opportunity to process the close notification so the
            // window visually disappears before the process exits.
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        menu.prepareForTerminationSynchronously()
        log("prepareForTerminationSynchronously() completed")
    }
}
