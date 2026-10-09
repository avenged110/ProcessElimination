// MARK: – STabAQ.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Process Elimination.app settings window: "App Quitter" tab (SwiftUI)
//
// The application list is an NSViewRepresentable wrapping NSTableView so that
// icon rendering, multi-selection, drag-and-drop, and undo work exactly as in
// the AppKit implementation. TCC state is driven by SettingsViewModel.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: – NSButtonView
// Thin NSViewRepresentable that wraps a single NSButton so that SwiftUI layouts
// get AppKit's native button sizing (bezel padding, minimum width) rather than
// SwiftUI's smaller intrinsic size for single-character labels.
// Matches the .rounded / .regular NSButton configuration used in STabPK.

private struct NSButtonView: NSViewRepresentable {
    // Read from the SwiftUI environment, NOT passed in as a parameter.
    //
    // This is the whole reason the "−" button could be enabled with nothing selected.
    // SwiftUI hosts an NSViewRepresentable inside a PlatformViewHost, and that host
    // applies the environment's isEnabled onto any hosted NSControl AFTER updateNSView
    // returns. An isEnabled the representable sets itself is therefore overwritten a
    // few milliseconds later by whatever the environment says — and since nothing in
    // this tab called .disabled(...) on the buttons, the environment always said
    // "enabled". Setting the property manually was simply futile: the assignment landed
    // and was then reverted, which is why the button appeared correct at first and
    // turned enabled after any pass that re-applied the environment.
    //
    // Reading \.isEnabled here and calling .disabled(...) at the call sites puts the
    // state in the environment, so the host applies the value this view actually wants
    // and there is nothing left to fight over.
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator,
                              action: #selector(Coordinator.handleClick))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.translatesAutoresizingMaskIntoConstraints = false
        // Applied HERE as well as in updateNSView. NSButton defaults to isEnabled == true,
        // so a button that only learns its state in updateNSView is enabled for the whole
        // window between being created and first updated. For the "−" button that meant it
        // came up clickable with nothing selected every time SwiftUI re-established this
        // view — which is what happened after an NSOpenPanel sheet was dismissed, leaving
        // "−" enabled after the user canceled out of the "+" dialog.
        button.isEnabled = isEnabled
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        // Agrees with what the host will apply from the environment, rather than
        // competing with it.
        button.isEnabled = isEnabled
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func handleClick() { action() }
    }
}

// MARK: – AppIconCache
// @MainActor-isolated icon and display-name cache for application bundle IDs.
//
// Synchronization model:
//   • All reads and writes to `store` and `pendingLoads` are @MainActor-isolated.
//     No additional locking or queue-based serialization is required.
//   • Resolution work (Launch Services, file I/O) is dispatched via
//     Task.detached so it runs off the main actor. Only Sendable values
//     (String and NSImage) cross into the detached task; the resolved
//     Entry is returned via `await` back to the main actor before being written
//     to `store`.
//   • `placeholder` is a `let` constant on the main actor. NSImage is Sendable
//     in the AppKit SDK, so the compiler verifies its transfer directly.
//
// Design invariants:
//   1. A bundle ID is inserted into `pendingLoads` before any off-actor work
//      begins, and removed only after the result has been written to `store`.
//      This prevents duplicate in-flight resolves for the same bundle ID.
//   2. `reloadData(forRowIndexes:)` is always invoked on the main thread and
//      never from inside an active NSTableView data-source callback.


@MainActor
final class AppIconCache {

    // Resolved entry stored for each bundle ID.
    // Entry instances are constructed inside a detached Task and then returned via
    // `await` to the main actor. Both members are Sendable (NSImage is, in the AppKit
    // SDK), so the compiler checks that transfer rather than taking it on trust.
    struct Entry: Sendable {
        let displayName: String
        let icon: NSImage
    }

    // Written and read exclusively on the main actor.
    private var store: [String: Entry] = [:]

    // Bundle IDs for which a background resolution task is already running.
    // Accessed exclusively on the main actor.
    private var pendingLoads: Set<String> = []

    // Generic .app placeholder icon. Initialized once on the main actor.
    // `icon(forFileType:)` is deprecated, but remains the only reliable way to obtain
    // the same generic bundle/wireframe icon that Finder shows for unknown .app bundles.
    let placeholder: NSImage = NSWorkspace.shared.icon(for: .applicationBundle)

    // MARK: – Read

    /// Returns the cached entry for `bundleID`, or `nil` if not yet resolved.
    func entry(for bundleID: String) -> Entry? {
        store[bundleID]
    }

    // MARK: – Write / resolve

    /// Ensures an icon-and-name entry exists for `bundleID`.
    /// If an entry is already cached or a load is already in flight, this is
    /// a no-op. `completion` is called on the main actor when resolution finishes.
    func resolve(
        bundleID: String,
        storedName: String,
        completion: @escaping () -> Void
    ) {
        if store[bundleID] != nil { return }
        if pendingLoads.contains(bundleID) { return }

        pendingLoads.insert(bundleID)

        // NSWorkspace is main-thread-only; perform the URL and icon lookups here
        // on the main actor before entering the detached task. Only the
        // FileManager.displayName call (which is thread-safe) is left to run
        // off-actor so the main thread is never blocked on file I/O.
        let id = bundleID
        let fallbackName = storedName
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let resolvedIcon: NSImage = appURL.map {
            NSWorkspace.shared.icon(forFile: $0.path)
        } ?? placeholder
        let placeholder = self.placeholder
        let appPath = appURL?.path  // String is Sendable; safe to capture

        Task {
            // Only FileManager.displayName(atPath:) runs off the main actor.
            // It is documented as thread-safe and performs no AppKit work.
            let entry: Entry = await Task.detached(priority: .userInitiated) {
                Self.buildEntry(
                    bundleID: id,
                    storedName: fallbackName,
                    appPath: appPath,
                    resolvedIcon: resolvedIcon,
                    placeholder: placeholder)
            }.value

            // Resume on the main actor (Task inherits the caller's actor).
            self.store[id] = entry
            self.pendingLoads.remove(id)
            completion()
        }
    }

    /// Resolves icons for every entry in `applications` off the main actor,
    /// then calls `completion` on the main actor once all are ready.
    /// Call before showing the table to avoid placeholder flicker on first display.
    func prewarm(
        applications: [BlacklistedApplication],
        completion: @escaping () -> Void
    ) {
        let needed = applications.filter {
            store[$0.bundleID] == nil && !pendingLoads.contains($0.bundleID)
        }
        guard !needed.isEmpty else { completion(); return }

        for app in needed { pendingLoads.insert(app.bundleID) }

        // Perform all NSWorkspace lookups on the main actor before dispatching.
        // NSWorkspace is main-thread-only; only the thread-safe FileManager
        // displayName call is deferred to the detached task.
        struct ResolveInput: Sendable {
            let id: String
            let storedName: String
            let appPath: String?
            let icon: NSImage
        }
        let placeholder = self.placeholder
        let inputs: [ResolveInput] = needed.map { app in
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: app.bundleID)
            let icon: NSImage = url.map {
                NSWorkspace.shared.icon(forFile: $0.path)
            } ?? placeholder
            return ResolveInput(
                id: app.bundleID,
                storedName: app.displayName,
                appPath: url?.path,
                icon: icon)
        }

        Task {
            let resolved: [String: Entry] = await Task.detached(priority: .userInitiated) {
                var results: [String: Entry] = [:]
                for input in inputs {
                    results[input.id] = Self.buildEntry(
                        bundleID: input.id,
                        storedName: input.storedName,
                        appPath: input.appPath,
                        resolvedIcon: input.icon,
                        placeholder: placeholder)
                }
                return results
            }.value

            for (id, entry) in resolved {
                self.store[id] = entry
                self.pendingLoads.remove(id)
            }
            completion()
        }
    }

    // MARK: – Nonisolated assembly helper
    // Constructs an Entry from already-resolved primitives. All NSWorkspace calls
    // have been performed on the main actor by the callers above; this function
    // only calls FileManager.displayName(atPath:), which is thread-safe, making
    // it safe to invoke from any concurrency context including Task.detached.
    private nonisolated static func buildEntry(
        bundleID: String,
        storedName: String,
        appPath: String?,
        resolvedIcon: NSImage,
        placeholder: NSImage
    ) -> Entry {
        if let path = appPath {
            // Use the stored display name when available; only fall back to the
            // file system name when the entry has no user-facing name recorded.
            let name = storedName.isEmpty
                ? FileManager.default.displayName(atPath: path)
                : storedName
            return Entry(displayName: name, icon: resolvedIcon)
        } else {
            let name = storedName.isEmpty ? bundleID : storedName
            return Entry(displayName: name, icon: placeholder)
        }
    }

    // MARK: – Invalidation

    /// Removes the cached entry for a single bundle ID.
    func invalidate(bundleID: String) {
        store.removeValue(forKey: bundleID)
        pendingLoads.remove(bundleID)
    }
}

// MARK: – KeyCommandView
// Zero-size NSView that answers this tab's key equivalents.
//
// The AQ tab is SwiftUI, and its "+", "−" and "Reset to Defaults" controls are
// NSButtonView (an NSViewRepresentable around NSButton), which neither SwiftUI's
// .keyboardShortcut nor an NSButton key equivalent can reach — so the ⌘N / ⌘R shortcuts
// the buttons' tooltips advertise had no implementation at all. AppKit's answer for this
// is performKeyEquivalent(with:): before any keyDown is dispatched, the key window walks
// its ENTIRE view tree offering the event to each view in turn. One view placed anywhere
// in the tab therefore sees the command no matter which control currently holds focus,
// which is the same reach SettingsTabPKController gets from overriding keyDown on its
// NSViewController — the responder chain equivalent for that tab's AppKit hierarchy.
//
// Plain Delete is deliberately NOT handled here. It carries no modifier, so it is not a
// key equivalent at all; it is handled by ApplicationTable.keyDown, which is reached only
// while the list itself has focus — matching what Delete does in the Process List tab.
//
// The window/visibility guard is load-bearing: NSTabViewController keeps every tab's view
// controller loaded and only swaps which one is on screen, so without it this tab would
// keep answering ⌘N and ⌘R while the Process List tab is in front. It is the same test
// SettingsFocusSink uses to decide whether its own tab is the one being displayed.
private struct KeyCommandView: NSViewRepresentable {

    struct KeyCommand {
        let key: Character
        let modifiers: NSEvent.ModifierFlags
        let action: () -> Void
    }

    let commands: [KeyCommand]

    func makeNSView(context: Context) -> CommandView {
        let view = CommandView()
        view.commands = commands
        return view
    }

    func updateNSView(_ nsView: CommandView, context: Context) {
        // Re-assigned on every body pass so the closures always act on current state.
        nsView.commands = commands
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CommandView,
                      context: Context) -> CGSize? {
        .zero
    }

    final class CommandView: NSView {
        var commands: [KeyCommand] = []

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard unsafe window != nil, !isHiddenOrHasHiddenAncestor else { return false }
            guard let characters = event.charactersIgnoringModifiers?.lowercased(),
                  characters.count == 1, let typed = characters.first else { return false }

            // Compare only the modifiers the user actually pressed: caps lock, the
            // function key and the numeric-pad flag ride along on ordinary key presses
            // and would otherwise defeat an exact match.
            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .function, .numericPad])

            for command in commands where command.key == typed && flags == command.modifiers {
                command.action()
                return true
            }
            return false
        }
    }
}

// MARK: – NSViewRepresentable: application list table
struct ApplicationTableView: NSViewRepresentable {

    @Binding var applications: [BlacklistedApplication]
    @Binding var selection: IndexSet
    // Shared icon cache injected from the parent so its lifetime is tied to
    // SettingsTabAQView, not to the coordinator (which SwiftUI may recreate).
    let iconCache: AppIconCache
    // Called once from makeNSView so the parent can hold the coordinator reference.
    var onCoordinatorReady: ((Coordinator) -> Void)?
    // Invoked when the list itself handles the Delete key. Re-assigned on every
    // updateNSView pass so it always acts on the current selection.
    var onDeleteSelection: (() -> Void)?

    // NSTableView subclass so the application list answers the plain Delete key the way
    // the Process List tab's table does. Delete carries no modifier, so it cannot be a key
    // equivalent and must be caught in keyDown on the responder that has focus.
    final class ApplicationTable: NSTableView {
        var onDelete: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            // 51 = Delete. The same keyCode SettingsTabPKController.keyDown tests for.
            if event.keyCode == 51, !selectedRowIndexes.isEmpty {
                onDelete?()
                return
            }
            super.keyDown(with: event)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(applications: $applications, selection: $selection,
                    iconCache: iconCache)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coord = context.coordinator

        // Defer the parent state mutation until after the current SwiftUI render pass
        // completes. Calling onCoordinatorReady synchronously here would mutate the
        // parent's @State (coordinator) while the view update is still in progress,
        // which triggers a "Modifying state during view update" runtime warning.
        // Task { @MainActor in } schedules the callback on the next main-runloop turn,
        // by which time SwiftUI's render pass has finished. The coordinator itself is
        // fully constructed and stable here, so deferring the callback is safe — no
        // button action can fire before the view appears on screen.
        Task { @MainActor in onCoordinatorReady?(coord) }

        let tv = coord.tableView
        tv.headerView = nil
        tv.allowsMultipleSelection = true
        tv.rowHeight = 22
        tv.usesAlternatingRowBackgroundColors = true
        tv.delegate = coord
        tv.dataSource = coord
        tv.allowsColumnResizing = false
        tv.registerForDraggedTypes([.fileURL])
        tv.setDraggingSourceOperationMask(.copy, forLocal: false)
        tv.draggingDestinationFeedbackStyle = .regular

        let col = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("ApplicationColumn"))
        col.title = "Application"
        col.minWidth = 320
        tv.addTableColumn(col)
        // Keep the single column flush with the scroll view's clip width at all
        // times. This prevents the column from being fractionally wider than the
        // visible area — the root cause of the invisible horizontal overflow.
        tv.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let sv = NSScrollView()
        sv.borderType = .bezelBorder
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.documentView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let coord = context.coordinator
        // Refreshed before the early return below: the handler must stay current even on
        // the passes where the list itself has not changed.
        coord.tableView.onDelete = onDeleteSelection
        guard coord.lastKnownApplications != applications else { return }
        coord.lastKnownApplications = applications
        coord.tableView.reloadData()
        // reloadData() can drop rows that were selected without notifying the delegate,
        // so the mirror is re-derived rather than left holding the old indices.
        coord.syncSelectionFromTable()
    }

    // MARK: – Coordinator
    // @MainActor ensures all AppKit delegate callbacks (which always arrive on the
    // main thread) and all @Binding mutations are isolation-consistent, eliminating
    // the Sendable warnings that arise when @Binding properties are accessed from
    // unstructured async or Dispatch contexts.
    @MainActor
    final class Coordinator: NSObject,
        NSTableViewDataSource, NSTableViewDelegate {

        @Binding var applications: [BlacklistedApplication]
        @Binding var selection: IndexSet
        let tableView = ApplicationTable()
        let iconCache: AppIconCache

        // Shadow copy for diffing in updateNSView.
        var lastKnownApplications: [BlacklistedApplication] = []

        init(applications: Binding<[BlacklistedApplication]>,
             selection: Binding<IndexSet>,
             iconCache: AppIconCache) {
            _applications = applications
            _selection = selection
            self.iconCache = iconCache
        }

        // MARK: NSTableViewDataSource
        func numberOfRows(in tableView: NSTableView) -> Int { applications.count }

        func tableView(_ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard applications.indices.contains(row) else { return nil }
            let entry = applications[row]
            let ident = NSUserInterfaceItemIdentifier("ApplicationCell")

            let cell: ApplicationCellView
            if let existing = tableView.makeView(
                withIdentifier: ident, owner: self) as? ApplicationCellView {
                cell = existing
            } else {
                cell = buildCell(identifier: ident)
            }

            if let cached = iconCache.entry(for: entry.bundleID) {
                // Cache hit — populate immediately with no async work needed.
                cell.label.stringValue = cached.displayName
                cell.icon.image = cached.icon
            } else {
                // Cache miss — show placeholder immediately, then resolve in the
                // background. The completion fires on the main actor and reloads
                // only this specific row, safely outside any data-source call.
                cell.label.stringValue = entry.displayName
                cell.icon.image = iconCache.placeholder

                let bundleID = entry.bundleID
                let storedName = entry.displayName
                iconCache.resolve(bundleID: bundleID, storedName: storedName) { [weak self] in
                    guard let self else { return }
                    // Re-derive the row index at callback time; the list may have
                    // changed since the resolve was enqueued.
                    guard let currentRow = self.applications.firstIndex(
                        where: { $0.bundleID == bundleID }) else { return }
                    self.tableView.reloadData(
                        forRowIndexes: IndexSet(integer: currentRow),
                        columnIndexes: IndexSet(integer: 0))
                }
            }
            return cell
        }

        private func buildCell(
            identifier: NSUserInterfaceItemIdentifier) -> ApplicationCellView {
            let imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyDown
            imageView.translatesAutoresizingMaskIntoConstraints = false

            let textField = NSTextField(labelWithString: "")
            textField.cell?.usesSingleLineMode = true
            textField.cell?.truncatesLastVisibleLine = true
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false

            let cell = ApplicationCellView(icon: imageView, label: textField)
            cell.identifier = identifier
            // Hard-clip backstop: if any subview somehow exceeds the cell bounds,
            // the layer mask prevents any pixel from rendering outside the row width.
            cell.wantsLayer = true
            cell.layer?.masksToBounds = true

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),

                textField.leadingAnchor.constraint(
                    equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(
                    equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

                cell.heightAnchor.constraint(greaterThanOrEqualToConstant: 22)
            ])
            return cell
        }

        /// Re-derives the `selection` mirror from the table's real selected rows.
        ///
        /// `selection` exists only because SwiftUI needs a value to re-render from; the
        /// NSTableView is the source of truth. Every path that can change the table's
        /// selection WITHOUT producing a tableViewSelectionDidChange callback — a
        /// reloadData() that drops the selected rows, a sheet handing first-responder
        /// status back — has to call this, or the mirror keeps reporting a selection the
        /// table is no longer showing and the "−" button stays enabled with nothing
        /// selected.
        func syncSelectionFromTable() {
            let current = tableView.selectedRowIndexes
            guard current != selection else { return }
            selection = current
        }

        // MARK: NSTableViewDelegate
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
        func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?,
            row: Int) -> Bool { false }
        func tableViewSelectionDidChange(_ notification: Notification) {
            let current = tableView.selectedRowIndexes
            guard current != selection else { return }
            selection = current
        }

        // MARK: Drag-and-drop (accepts .app bundles dragged from Finder)
        func tableView(_ tableView: NSTableView,
            validateDrop info: any NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOp: NSTableView.DropOperation) -> NSDragOperation {
            let pb = info.draggingPasteboard
            guard let urls = pb.readObjects(forClasses: [NSURL.self],
                options: nil) as? [URL],
                urls.contains(where: { $0.pathExtension.lowercased() == "app" })
            else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .copy
        }

        func tableView(_ tableView: NSTableView,
            acceptDrop info: any NSDraggingInfo, row: Int,
            dropOperation: NSTableView.DropOperation) -> Bool {
            guard let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: nil) as? [URL]
            else { return false }
            let appURLs = urls.filter { $0.pathExtension.lowercased() == "app" }
            guard !appURLs.isEmpty else { return false }
            var addedIndices = IndexSet()
            for url in appURLs {
                let prev = applications.count
                processURL(url)
                if applications.count > prev { addedIndices.insert(applications.count - 1) }
            }
            if !addedIndices.isEmpty {
                tableView.selectRowIndexes(addedIndices, byExtendingSelection: false)
                if let last = addedIndices.last { tableView.scrollRowToVisible(last) }
                unsafe tableView.window?.makeFirstResponder(tableView)
                selection = tableView.selectedRowIndexes
            }
            return true
        }

        // MARK: – Shared URL-processing logic (open panel + drag-drop)
        func processURL(_ url: URL?) {
            guard let url, url.pathExtension.lowercased() == "app" else { return }
            guard let bundle = Bundle(url: url),
                let bundleID = bundle.bundleIdentifier else { return }

            let displayName = FileManager.default.displayName(atPath: url.path)

            // Routes through the same whitelist + duplicate validator STabPK uses for
            // its process list. This was previously bypassed here — a bare, case-
            // sensitive `applications.contains` check stood in its place — which meant
            // InputValidation.validateApplicationEntry's rejection of whitelisted
            // system bundle IDs (e.g. com.apple.finder) was never actually enforced
            // for drag-and-drop or the "+" open panel. Presenting the alert here also
            // gives the user visible feedback instead of a silent no-op on duplicates.
            guard InputValidation.validateApplicationEntry(
                bundleID: bundleID,
                displayName: displayName,
                currentList: applications,
                in: tableView
            ) else { return }

            let newEntry = BlacklistedApplication(bundleID: bundleID, displayName: displayName)

            // Invalidate any stale entry so the resolve below always runs fresh.
            iconCache.invalidate(bundleID: bundleID)

            applications.append(newEntry)
            Preferences.blacklistedApplications = applications

            let rowIndex = applications.count - 1

            // Resolve the icon for the new row. The LS cache makes this near-instant
            // for apps that were just browsed, so the placeholder is rarely visible.
            // The row is re-derived at callback time, as in tableView(_:viewFor:row:): an
            // earlier row removed while the resolve was in flight would otherwise shift
            // this entry and reload a different row.
            iconCache.resolve(bundleID: bundleID, storedName: displayName) { [weak self] in
                guard let self,
                      let currentRow = self.applications.firstIndex(
                        where: { $0.bundleID == bundleID }) else { return }
                self.tableView.reloadData(
                    forRowIndexes: IndexSet(integer: currentRow),
                    columnIndexes: IndexSet(integer: 0))
            }

            tableView.beginUpdates()
            tableView.insertRows(at: IndexSet(integer: rowIndex), withAnimation: [])
            tableView.endUpdates()

            // The table is now in step with `applications`, so record that here. Without
            // it, the binding write above reaches updateNSView on the next SwiftUI pass,
            // the shadow copy still disagrees, and the whole table is reloaded a second
            // time for rows insertRows has already placed correctly.
            lastKnownApplications = applications

            // Force a layout pass to prevent the single-row compression glitch.
            // Already on main; the async hop defers until after AppKit's internal
            // update pass completes.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let all = IndexSet(integersIn: 0..<self.tableView.numberOfRows)
                self.tableView.noteHeightOfRows(withIndexesChanged: all)
                self.tableView.layoutSubtreeIfNeeded()
                self.tableView.displayIfNeeded()
            }
        }
    }
}

// MARK: – GraceDelayField
// NSViewRepresentable wrapping an AppKit NSTextField with WholeIntegerFormatter attached.
// Using AppKit here (instead of SwiftUI TextField) gives us the formatter's
// isPartialStringValid pre-storage intercept — SwiftUI's TextField has no equivalent
// hook for character-class filtering at the keystroke level on macOS 14. This matches
// the approach used for the process-kill interval field in STabPK.
//
// .roundedBezel gives the field the same rounded-rectangle appearance as a SwiftUI
// TextField, keeping both tabs visually consistent.
//
// onCommit receives the NSTextField sender so the caller can pass it directly to
// InputValidation.validateIntegerField, which needs it for field reversion and for
// locating the window to attach the out-of-range alert sheet.
// onBeginEdit is called when the field becomes first responder, giving the parent a
// chance to snapshot priorGraceDelayText before edits begin.
private struct GraceDelayField: NSViewRepresentable {
    // Environment-driven for the same reason as NSButtonView: SwiftUI's host re-applies
    // the environment's isEnabled onto the hosted NSTextField after updateNSView, so a
    // manually assigned value does not survive. The call site uses .disabled(...).
    @Environment(\.isEnabled) private var isEnabled

    @Binding var text: String
    let onCommit: (NSTextField) -> Void
    let onBeginEdit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit, onBeginEdit: onBeginEdit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.alignment = .center
        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = context.coordinator
        field.formatter = WholeIntegerFormatter()
        field.bezelStyle = .roundedBezel
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.isEnabled = isEnabled
        // Only update the field's string value when it is not being edited;
        // overwriting it mid-edit would discard the user's in-progress input.
        if field.currentEditor() == nil {
            field.stringValue = text
        }
        context.coordinator.onCommit = onCommit
        context.coordinator.onBeginEdit = onBeginEdit
    }

    // @MainActor: NSTextFieldDelegate callbacks always arrive on the main thread.
    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: (NSTextField) -> Void
        var onBeginEdit: () -> Void

        init(onCommit: @escaping (NSTextField) -> Void, onBeginEdit: @escaping () -> Void) {
            self.onCommit = onCommit
            self.onBeginEdit = onBeginEdit
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            onBeginEdit()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            onCommit(field)
        }
    }
}

// MARK: – Tab view
struct SettingsTabAQView: View {
    @ObservedObject var viewModel: SettingsViewModel

    @State private var applications: [BlacklistedApplication] =
        Preferences.blacklistedApplications
    @State private var originalApplications: [BlacklistedApplication] =
        Preferences.blacklistedApplications
    @State private var selection: IndexSet = []
    @State private var showResetConfirmation = false
    @State private var showPermissionSheet = false
    @State private var coordinator: ApplicationTableView.Coordinator?

    // Grace delay editing state. graceDelayText is the live string in the field;
    // it is committed to Preferences (and validated as a whole integer) on focus loss,
    // matching the interval field behavior in STabPK exactly.
    @State private var graceDelayText: String = "\(Preferences.aqGraceDelaySeconds)"
    // Shadow copy used to revert on invalid input, kept in sync on commit.
    @State private var priorGraceDelayText: String = "\(Preferences.aqGraceDelaySeconds)"

    // True after onCoordinatorReady has fired at least once. Used to distinguish
    // first appearance (coordinator not yet set when onAppear fires) from subsequent
    // appearances (coordinator already set and valid).
    @State private var coordinatorReady = false

    // Stays false until onAppear has fully fired. Ensures the "−" button is
    // unconditionally disabled during the initial render pass so it never
    // flickers enabled-then-disabled before the table selection is settled.
    @State private var tabDidLoad = false

    // Reads the session-lifetime cache from the view model rather than owning
    // a local copy. The cache is never torn down by tab switches or window
    // close/reopen, so icons resolved in one session persist for all subsequent
    // appearances of the tab within the same app launch.
    private var iconCache: AppIconCache { viewModel.iconCache }

    private var accessGranted: Bool { viewModel.aqAccessGranted }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Single-line header matching the STabPK layout: label + field + label,
            // baseline-aligned in an HStack so it occupies exactly one row.
            HStack(spacing: 6) {
                Text("Auto. quit these apps after")
                    .foregroundStyle(accessGranted ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                GraceDelayField(
                    text: $graceDelayText,
                    onCommit: { field in commitGraceDelay(field) },
                    onBeginEdit: { priorGraceDelayText = graceDelayText }
                )
                .disabled(!accessGranted)
                .frame(width: 48)
                Text("sec. when their last window is closed:")
                    .foregroundStyle(accessGranted ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            }
            .frame(minHeight: SettingsLayout.headerHeight, alignment: .topLeading)

            // Application list table
            ApplicationTableView(
                applications: $applications,
                selection: $selection,
                iconCache: iconCache,
                onCoordinatorReady: { coord in
                    coordinator = coord
                    coordinatorReady = true
                    // First-load sync: onAppear fires before the coordinator exists
                    // because makeNSView defers onCoordinatorReady one run-loop turn
                    // via Task { @MainActor in }. The prewarm completion inside
                    // syncFromPreferences captures [weak coordinator]; if that
                    // reference is nil the reload is a silent no-op. By calling
                    // syncFromPreferences here — after the coordinator is guaranteed
                    // set — the completion can always reach the table.
                    syncFromPreferences()
                    tabDidLoad = true
                },
                onDeleteSelection: { removeSelectedApplications() }
            )
            .disabled(!accessGranted)
            .opacity(accessGranted ? 1.0 : 0.5)
            // onAppear fires before onCoordinatorReady on the very first load;
            // skip the sync then because onCoordinatorReady handles it above.
            // On all subsequent appearances (tab switch back, window reopen) the
            // coordinator is already set so the sync proceeds normally.
            .onAppear {
                guard coordinatorReady else { return }
                syncFromPreferences()
                tabDidLoad = true
            }

            // Buttons row
            // "+" and "−" use NSButtonView (NSViewRepresentable) so their bezel
            // sizing is driven by AppKit's NSButtonCell, matching STabPK exactly.
            HStack(spacing: 8) {
                NSButtonView(title: "+") { addApplication() }
                    .disabled(!accessGranted)
                    .fixedSize()
                    .help("Add an application to the list (⌘N)")

                // Enabled only while the table actually has a selection. Expressed as
                // .disabled(...) so the value reaches NSButtonView through the
                // environment — see the note on NSButtonView.isEnabled for why setting
                // the control's property directly does not survive.
                NSButtonView(title: "−") {
                    removeSelectedApplications()
                }
                .disabled(!(tabDidLoad && accessGranted && !selection.isEmpty))
                .fixedSize()
                .help("Remove the selected entries (Delete)")

                NSButtonView(title: "Reset to Defaults") {
                    showResetConfirmation = true
                }
                .disabled(!accessGranted)
                .fixedSize()
                .help("Reset the application list to built-in defaults (⌘R)")

                Spacer()

                // "Why is This Disabled?" appears only when permission is denied.
                // Presents as a sheet attached to the settings window, consistent with
                // the "Reset to Defaults" confirmation alert above. The menu-bar path
                // (StatusMenuController) continues to use the standalone runModal variant.
                if !accessGranted {
                    Button("Why is This Disabled?") {
                        showPermissionSheet = true
                    }
                }
            }
        }
        .padding(.top, SettingsLayout.tabTopPadding)
        .padding(.leading, 18)
        .padding(.trailing, 18)
        .padding(.bottom, 18)
        // Fills the window's measured height; the table takes the slack.
        .frame(maxHeight: .infinity)
        .frame(width: SettingsLayout.contentWidth)
        // Keyboard equivalents for this tab's buttons, matching the shortcuts their
        // tooltips advertise and the set SettingsTabPKController implements for the
        // Process List tab. Attached as a zero-size background rather than as a member of
        // the VStack above, so it contributes neither size nor an extra 12 pt of stack
        // spacing to the layout. Delete is handled by ApplicationTable.keyDown instead —
        // see KeyCommandView for why.
        //
        // Each action re-checks accessGranted: the controls these mirror are disabled
        // without the Accessibility grant, and a shortcut must not be a way around that.
        .background(
            KeyCommandView(commands: [
                .init(key: "n", modifiers: .command) {
                    guard accessGranted else { return }
                    addApplication()
                },
                .init(key: "r", modifiers: .command) {
                    guard accessGranted else { return }
                    showResetConfirmation = true
                },
            ])
            .frame(width: 0, height: 0)
        )
        .onDisappear {
            persistIfChanged()
            tabDidLoad = false
            // This view's NSHostingController (and therefore this SwiftUI view's
            // @State, including `selection`) is not torn down on tab switches —
            // NSTabViewController keeps every tab's content controller loaded in
            // memory and only swaps which one is on screen. Without clearing both
            // the AppKit table's own selection and the `selection` state mirror
            // here, a selection made before switching tabs would still make the
            // "−" button eligible to enable on return (once tabDidLoad flips back
            // to true in onAppear), even though the table shows nothing selected.
            coordinator?.tableView.deselectAll(nil)
            selection = []
        }
        .onReceive(Preferences.preferencesChanged) { key in
            if key == Preferences.Keys.blacklistedApplications {
                syncFromPreferences()
            } else if key == Preferences.Keys.aqGraceDelaySeconds {
                let formatted = "\(Preferences.aqGraceDelaySeconds)"
                graceDelayText = formatted
                priorGraceDelayText = formatted
            }
        }
        .alert("Reset Blacklist to Defaults", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) { resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to reset the list of blacklisted applications to the default values?")
        }
        // Permission explanation sheet — attaches to the settings window, matching the
        // "Reset to Defaults" alert presentation style. The menu-bar "Application Quitter"
        // toggle uses PermissionController.showPermissionAlert() (runModal) instead because
        // no key window is guaranteed to be available as a sheet target from a menu action.
        .alert("Accessibility Access Required", isPresented: $showPermissionSheet) {
            Button("Open Settings") {
                if let url = URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
                Process Elimination cannot reliably quit applications without being granted \
                "Accessibility" permissions.

                This must be done manually.

                You must first grant permission in \
                System Settings → Privacy & Security.
                """)
        }
    }

    // MARK: – Actions
    // Validates and persists the grace delay text field value.
    // Called on focus loss (NSTextField delegate) via GraceDelayField.onCommit.
    // Delegates fully to InputValidation.validateIntegerField, giving identical
    // behavior to the process-kill interval field in STabPK: WholeIntegerFormatter
    // guarantees only digit characters reach this point, so only the bounds need
    // checking. Out-of-range values trigger an alert sheet and revert the field.
    private func commitGraceDelay(_ sender: NSTextField) {
        InputValidation.validateIntegerField(
            sender, min: 1, max: 60,
            getCurrent: { Preferences.aqGraceDelaySeconds },
            setNew: { Preferences.aqGraceDelaySeconds = $0 },
            revertValue: priorGraceDelayText,
            errorMessage: "You must enter a whole number between 1 and 60.",
            in: sender)
        // Keep graceDelayText in sync with whatever validateIntegerField wrote
        // to the field so the @Binding and the NSTextField stay consistent.
        graceDelayText = sender.stringValue
        priorGraceDelayText = sender.stringValue
    }

    private func addApplication() {
        Task { @MainActor in
            let config = OpenPanelConfiguration(
                canChooseFiles: true,
                canChooseDirectories: false,
                allowsMultipleSelection: true,
                allowedContentTypes: [.application],
                title: "Choose an Application")
            let result = await OpenPanelPresenter.present(configuration: config)
            // Re-derived on EVERY exit path, cancellation included. Dismissing the panel
            // returns first-responder status to the settings window and gives SwiftUI a
            // pass in which it may rebuild this tab's views; what the table actually has
            // selected at that moment — not whatever the mirror last recorded — is what
            // the "−" button must reflect. On the success path processURLs has already
            // set the selection, and this simply confirms it.
            defer { coordinator?.syncSelectionFromTable() }
            guard case .urls(let urls) = result else { return }
            processURLs(urls)
        }
    }

    private func processURLs(_ urls: [URL]) {
        var addedIndices = IndexSet()
        for url in urls {
            let prev = applications.count
            coordinator?.processURL(url)
            if applications.count > prev { addedIndices.insert(applications.count - 1) }
        }
        if !addedIndices.isEmpty {
            // The added rows are deliberately NOT selected. Dismissing the open panel
            // hands first-responder status back to the settings window, and the SwiftUI
            // pass that follows reloads the table and drops whatever was selected — so a
            // selection made here survived for exactly one frame, flickering the rows and
            // the "−" button on and straight back off. Matching STabPK, the new entry is
            // simply scrolled into view and left unselected, which is also the only state
            // consistent with "− is enabled iff something is actually selected".
            coordinator?.tableView.deselectAll(nil)
            if let last = addedIndices.last {
                coordinator?.tableView.scrollRowToVisible(last)
            }
            unsafe coordinator?.tableView.window?.makeFirstResponder(coordinator?.tableView)
            selection = []
        }
    }

    private func removeSelectedApplications() {
        guard accessGranted else { return }
        // The table's own selected rows, not the `selection` mirror: this method deletes
        // data, so a mirror that had drifted out of step would remove rows the user never
        // saw selected. The mirror is corrected from the same read before returning.
        let rows = coordinator?.tableView.selectedRowIndexes ?? []
        guard !rows.isEmpty else {
            selection = []
            return
        }
        // Invalidate removed entries so stale icons don't survive a re-add.
        for index in rows {
            if applications.indices.contains(index) {
                iconCache.invalidate(bundleID: applications[index].bundleID)
            }
        }
        applications.remove(atOffsets: rows)
        selection = []
        Preferences.blacklistedApplications = applications
        originalApplications = applications

        // Reload the table on the next run-loop turn, after AppKit's own internal
        // update pass finishes. reloadData() already invalidates the full visible
        // region; for a fixed-height table the additional noteHeightOfRows /
        // layoutSubtreeIfNeeded / displayIfNeeded calls that were here are redundant
        // and have been removed.
        Task { @MainActor in
            coordinator?.tableView.reloadData()
            coordinator?.tableView.deselectAll(nil)
            selection = []
        }
    }

    private func resetToDefaults() {
        Preferences.resetApplicationBlacklistToDefaults()
        syncFromPreferences()
    }

    // Synchronizes the view state with the persisted preferences list and ensures
    // the icon cache is current without discarding entries that are still valid.
    //
    // Invalidation strategy: only bundle IDs that are no longer present in the
    // incoming list are evicted from the cache. Entries whose bundle ID appears
    // in both the old and new list are kept, so the table can render their icons
    // immediately on the first data-source pass without waiting for an async
    // resolve. Only genuinely new entries (and those just evicted) go through the
    // background resolve path, which updates each row progressively as it completes.
    private func syncFromPreferences() {
        let fresh = Preferences.blacklistedApplications
        let freshIDs = Set(fresh.map(\.bundleID))

        // Evict entries whose bundle ID is no longer in the incoming list.
        // This covers both reset-to-defaults (the list changes wholesale) and
        // external preference mutations. Retained entries are served from cache
        // immediately; their resolve path is a no-op in AppIconCache.resolve.
        for app in applications where !freshIDs.contains(app.bundleID) {
            iconCache.invalidate(bundleID: app.bundleID)
        }

        applications = fresh
        originalApplications = fresh

        // Prewarm: kick off background resolution for any entry not already in
        // the cache. AppIconCache.prewarm skips bundle IDs already present, so
        // this is a no-op for the common case where the list has not changed.
        // The completion fires on the main actor and triggers a full reload so
        // any rows that were not yet cached render with real icons once ready.
        iconCache.prewarm(applications: fresh) { [weak coordinator] in
            coordinator?.tableView.reloadData()
            coordinator?.syncSelectionFromTable()
        }
    }

    private func persistIfChanged() {
        guard applications != originalApplications else { return }
        Preferences.blacklistedApplications = applications
        originalApplications = applications
    }
}

// MARK: – ApplicationCellView
// NSTableCellView.imageView and .textField are declared unsafe_unretained (`assign`) in
// the AppKit SDK, so every read of them is an unchecked, non-owning access. This subclass
// holds both views strongly in `icon` and `label`, which is what the data source reads;
// the AppKit outlets are still set, once, so that AppKit's own cell behavior (selection
// text color, accessibility) is unchanged. Both are also subviews, so the unretained
// pointers never outlive them.
final class ApplicationCellView: NSTableCellView {
    let icon: NSImageView
    let label: NSTextField

    init(icon: NSImageView, label: NSTextField) {
        self.icon = icon
        self.label = label
        super.init(frame: .zero)
        addSubview(icon)
        addSubview(label)
        unsafe imageView = icon
        unsafe textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
