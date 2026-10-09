// MARK: – SettingsView.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Process Elimination.app settings window content.
//
// The window shell, the launch-at-login control, the log-file monitor, the whole Debug
// Logging block and the temporary main menu now come from the shared
// SettingsKit.swift. What remains here is Process Elimination's own: the shared
// layout constants, the observable view model threaded into every tab, and the General
// tab's contents. The "Process List" and "App Quitter" tabs live in STabPK.swift and
// STabAQ.swift and are unchanged.
//
// There is no "About" tab: About is the standard macOS about panel, which picks up the
// GPL-3.0 text from Credits.html in the app bundle's Resources.

import Cocoa
import Combine
import SwiftUI

// MARK: – Window content dimensions
// Single authoritative source for the settings window's content area size.
// Adjust here and all tab views will pick it up automatically.
// Note: these describe the *content* area — the tab toolbar strip sits above it and is
// accounted for automatically by the shared SettingsWindowController, so the total
// window frame will be slightly taller.
// Internal (not private) so STabPK.swift and STabAQ.swift can reference it directly,
// keeping all dimension values in one place.
enum SettingsLayout {
    static let contentWidth: CGFloat = 500
    // The window's height is measured from the General tab (`.fitToContent`), and the two
    // table tabs fill whatever that is — but a table needs room for rows regardless of
    // how few controls General carries, so the window never drops below this.
    static let minimumContentHeight: CGFloat = 326
    // Reserved vertical space for the header row on PK and AQ tabs.
    // The PK header is an HStack containing a TextField (~22 pt tall); the AQ
    // header is a plain Text (~17 pt). Fixing both to this height ensures the
    // table's top edge sits at the same Y position on every tab switch.
    static let headerHeight: CGFloat = 22
    // Top padding for the PK and AQ tab content areas. Controls the space between
    // the above-table header text and the top edge of the tab view. Leading,
    // trailing, and bottom padding are fixed at 18 pt and are not exposed here.
    // To diverge the two tabs, replace the reference in either STabPK.swift or
    // STabAQ.swift with a literal instead.
    static let tabTopPadding: CGFloat = 15
}

// MARK: – SettingsViewModel
// Observable state hub shared between the shared window shell and all SwiftUI tab views.

@MainActor
final class SettingsViewModel: ObservableObject {

    // MARK: – App Quitter tab
    @Published var aqAccessGranted: Bool = PermissionController.aqAccessGranted()

    // Icon cache for the App Quitter tab. Owned here so it lives for the
    // entire runtime session — independent of whether the AQ tab view is
    // on screen — and is never wiped by tab switches or window close/reopen.
    let iconCache = AppIconCache()

    // MARK: – Mutations called by the window shell
    func refreshAQState() {
        aqAccessGranted = PermissionController.aqAccessGranted()
    }
}

// MARK: – General Tab
// Launch-at-login and all debug-logging controls in one column, built from the shared
// SettingsKit pieces: SettingsPage supplies the grid, LaunchAtLoginToggle keeps
// itself in sync with SMAppService, and SettingsLoggingSection is the whole Debug
// Logging block (toggle, caption, Reveal/Clear buttons, its own LogFileMonitor, and the
// correct logForced + shutdownLogging handling on disable).

@MainActor
struct SettingsTabGeneralView: View {

    // viewModel is accepted for API compatibility with the other tab views, which all
    // take it so the tab-spec call sites stay uniform. This tab consumes no viewModel
    // state directly.
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        SettingsPage {
            LaunchAtLoginToggle()

            Divider()

            SettingsLoggingSection(
                loggingEnabledKey: Preferences.Keys.loggingEnabled,
                title: "Debug logging")

            Spacer(minLength: 0)
        }
        .frame(width: SettingsLayout.contentWidth, alignment: .topLeading)
    }
}
