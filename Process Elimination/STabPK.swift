// MARK: – STabPK.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Process Elimination.app settings window: "Process List" tab
//
// The full process-table implementation lives in SettingsTabPKController, a pure-AppKit
// NSViewController. SettingsTabPKView wraps it via NSViewControllerRepresentable so it
// integrates seamlessly with SettingsTabViewController's NSHostingController-based tab
// system, while sidestepping the SwiftUI binding-mutation / updateNSView race conditions
// that caused broken "+" button behavior in the prior SwiftUI-centric approach.

import SwiftUI
import AppKit
import Combine

// MARK: – NSViewControllerRepresentable wrapper

struct SettingsTabPKView: NSViewControllerRepresentable {
    // viewModel is accepted for API compatibility with SettingsTabViewController,
    // which threads it into every tab. The PK tab does not consume any viewModel
    // properties directly, but accepting it keeps the addTab call-site uniform.
    @ObservedObject var viewModel: SettingsViewModel

    func makeNSViewController(context: Context) -> SettingsTabPKController {
        SettingsTabPKController()
    }

    func updateNSViewController(_ nsViewController: SettingsTabPKController,
                                context: Context) {
        // No SwiftUI-driven updates needed; the controller manages all of its
        // own state internally via Preferences and in-memory snapshots.
    }
}

// MARK: – SettingsTabPKController
// Pure-AppKit NSViewController that owns the process-blacklist table UI.
// This is a faithful port of the original SettingsTabPK implementation with
// all proven add/edit/remove/undo/keyboard logic restored intact.

final class SettingsTabPKController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, Loggable {

    nonisolated static let logTag = "[STabPK]"

    // MARK: – Stored UI references
    private var intervalField: NSTextField!
    private var processesTable: NSTableView!
    // Held so addProcess can force the enclosing scroll view through a layout pass
    // before asking it to scroll a just-inserted row into view.
    private var tableScrollView: NSScrollView!
    private var removeProcessButton: NSButton!

    // MARK: – State
    private var priorIntervalString: String?
    // Combine cancellable for the Preferences.preferencesChanged subscription.
    // Storing it as AnyCancellable means cancellation (and observer teardown)
    // happens automatically when this controller is deallocated, with no manual
    // removeObserver call needed in deinit.
    private var blacklistCancellable: AnyCancellable?
    private var lastAddedRow: Int?
    private var deletedBatchesStack: [(rows: IndexSet, items: [String])] = []

    // In-memory snapshot; persisted on change.
    private var processBlacklist: [String] = []
    private var originalProcessBlacklist: [String] = []

    // Table column identifier
    private let kProcessColumnID = NSUserInterfaceItemIdentifier("ProcessColumn")

    // MARK: – Init / deinit
    init() {
        super.init(nibName: nil, bundle: nil)
        processBlacklist = Preferences.blacklistedProcesses
        originalProcessBlacklist = processBlacklist
        self.log("init() — loaded process blacklist with \(processBlacklist.count) entries.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // deinit is now empty: AnyCancellable cancels the subscription automatically.

    // MARK: – Blacklist persistence
    private func persistProcessBlacklistIfChanged() {
        guard processBlacklist != originalProcessBlacklist else {
            self.log("Process blacklist unchanged — no persistence required")
            return
        }
        Preferences.blacklistedProcesses = processBlacklist
        self.log("Blacklisted processes updated (persisted)")
        originalProcessBlacklist = processBlacklist
    }

    // MARK: – viewDidLoad
    override func viewDidLoad() {
        super.viewDidLoad()
        // Subscribe to Preferences.preferencesChanged. Receiving on RunLoop.main
        // guarantees table reloads happen on the main actor. The subscription is
        // stored in blacklistCancellable; it is automatically canceled and released
        // when this controller deallocates — no manual removeObserver call required.
        blacklistCancellable = Preferences.preferencesChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] key in
                guard let self else { return }
                if key == Preferences.Keys.processKillIntervalSeconds {
                    // The interval can change without this field having been the source:
                    // the Preferences getter repairs an out-of-range value on read, and
                    // any other writer fires the same event. Without this branch the
                    // visible field silently disagreed with the value actually in use.
                    // (STabAQ already does exactly this for aqGraceDelaySeconds.)
                    let formatted = "\(Preferences.processKillIntervalSeconds)"
                    // Never overwrite text the user is part-way through typing.
                    if intervalField.currentEditor() == nil {
                        intervalField.stringValue = formatted
                    }
                    priorIntervalString = formatted
                } else if key == Preferences.Keys.blacklistedProcesses {
                    // Re-read the authoritative persisted list before reloading the
                    // table. The in-memory snapshot (processBlacklist) may be stale
                    // if the change originated outside this controller — for example,
                    // from resetProcessBlacklistToDefaults() in AppDelegate or another
                    // code path that writes Preferences directly. Refreshing both
                    // processBlacklist and originalProcessBlacklist here ensures the
                    // data source and the dirty-check baseline are both current.
                    let fresh = Preferences.blacklistedProcesses
                    processBlacklist = fresh
                    originalProcessBlacklist = fresh
                    processesTable.reloadData()
                    // reloadData can drop the selection without posting a change
                    // notification, so re-derive the "−" button from the table.
                    updateRemoveButtonState()
                }
            }
    }

    // MARK: – loadView  (builds entire UI programmatically)
    override func loadView() {
        // Give the root view a concrete frame matching the locked content size.
        // This is the AppKit equivalent of SwiftUI's .frame(width:height:) on the
        // outermost container. Without an explicit size here, Auto Layout has no
        // concrete height to resolve the verticalStack's bottom-anchor constraint
        // against, which causes the table to collapse and the header to expand.
        // The window pins the view to its own (measured) size once hosted; this is only
        // the initial frame Auto Layout resolves against.
        let contentSize = NSSize(width: SettingsLayout.contentWidth,
                                 height: SettingsLayout.minimumContentHeight)
        self.view = NSView(frame: NSRect(origin: .zero, size: contentSize))
        self.preferredContentSize = contentSize

        // --- Process Kill Interval -------------------------------------------
        intervalField = NSTextField(string: "\(Preferences.processKillIntervalSeconds)")
        intervalField.alignment = .center
        intervalField.translatesAutoresizingMaskIntoConstraints = false
        intervalField.delegate = self
        // WholeIntegerFormatter intercepts every keystroke, paste, and drag-drop
        // before it reaches text storage, silently stripping any character that is
        // not a decimal digit (including '.', '-', letters, etc.). This means only
        // whole integers can ever appear in the field; validateIntegerField at commit
        // time only needs to check the bounds, not the character class.
        intervalField.formatter = WholeIntegerFormatter()
        intervalField.bezelStyle = .roundedBezel
        intervalField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        priorIntervalString = "\(Preferences.processKillIntervalSeconds)"

        let headerPrefix = NSTextField(
            labelWithString: "Automatically terminate these processes every")
        let headerSuffix = NSTextField(labelWithString: "seconds:")
        let headerStack = NSStackView(views: [headerPrefix, intervalField, headerSuffix])
        headerStack.orientation = .horizontal
        headerStack.alignment = .firstBaseline
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        // Container is pinned to exactly SettingsLayout.headerHeight so that the
        // table's top edge sits at the same Y position as on the AQ tab.
        // The headerStack is top-aligned within the container, matching the
        // SwiftUI Text + minHeight frame in STabAQ which also top-aligns its
        // content when the text is shorter than the reserved slot.
        let headerContainer = NSView()
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(headerStack)
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: headerContainer.topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            headerStack.trailingAnchor.constraint(
                lessThanOrEqualTo: headerContainer.trailingAnchor),
            headerContainer.heightAnchor.constraint(
                equalToConstant: SettingsLayout.headerHeight)
        ])

        // --- Blacklist table -------------------------------------------------
        let tableScroll = NSScrollView()
        tableScroll.borderType = .bezelBorder
        tableScroll.hasVerticalScroller = true
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        processesTable = NSTableView()
        processesTable.headerView = nil
        processesTable.allowsMultipleSelection = true
        processesTable.rowHeight = 22
        processesTable.usesAlternatingRowBackgroundColors = true
        processesTable.delegate = self
        processesTable.dataSource = self
        // Deliberately left on Auto Layout's translated-mask path (the AppKit default).
        // A scroll view's document view sizes itself by frame: NSTableView grows its own
        // height as rows are added and NSClipView derives the document rect from that.
        // Setting translatesAutoresizingMaskIntoConstraints = false here handed the
        // table's frame to Auto Layout, which — with no height constraint of its own to
        // satisfy — clamped it to the clip view. The document then never grew past the
        // viewport, so an appended row sat outside the scrollable area and was visible
        // only in rubber-band overscroll until an unrelated pass reset the frame.

        let col = NSTableColumn(identifier: kProcessColumnID)
        col.title = "Blacklisted process (exact executable name)"
        col.minWidth = 320
        processesTable.addTableColumn(col)
        // Keep the single column flush with the scroll view's clip width at all
        // times. This prevents the column from being fractionally wider than the
        // visible area — the root cause of the invisible horizontal overflow.
        processesTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableScroll.documentView = processesTable
        tableScrollView = tableScroll

        // --- Buttons --------------------------------------------------------
        // All three buttons use .rounded bezelStyle and .regular controlSize so
        // they render identically to the SwiftUI Button views in the AQ tab.
        let addButton = NSButton(
            title: "+", target: self, action: #selector(addProcess(_:)))
        addButton.bezelStyle = .rounded
        addButton.controlSize = .regular
        addButton.translatesAutoresizingMaskIntoConstraints = false

        removeProcessButton = NSButton(
            title: "−", target: self, action: #selector(removeProcess(_:)))
        removeProcessButton.bezelStyle = .rounded
        removeProcessButton.controlSize = .regular
        removeProcessButton.translatesAutoresizingMaskIntoConstraints = false
        removeProcessButton.isEnabled = false

        let resetButton = NSButton(
            title: "Reset to Defaults", target: self,
            action: #selector(resetProcessBlacklistToDefaults(_:)))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .regular
        resetButton.translatesAutoresizingMaskIntoConstraints = false

        let addRemoveStack = NSStackView(
            views: [addButton, removeProcessButton, resetButton])
        addRemoveStack.orientation = .horizontal
        addRemoveStack.spacing = 8
        addRemoveStack.translatesAutoresizingMaskIntoConstraints = false

        // --- Layout ---------------------------------------------------------
        let verticalStack = NSStackView(
            views: [headerContainer, tableScroll, addRemoveStack])
        verticalStack.orientation = .vertical
        verticalStack.alignment = .leading
        verticalStack.spacing = 12
        verticalStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(verticalStack)

        NSLayoutConstraint.activate([
            verticalStack.topAnchor.constraint(
                equalTo: view.topAnchor, constant: SettingsLayout.tabTopPadding),
            verticalStack.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: 18),
            verticalStack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -18),
            verticalStack.bottomAnchor.constraint(
                equalTo: view.bottomAnchor, constant: -18),

            tableScroll.leadingAnchor.constraint(equalTo: verticalStack.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: verticalStack.trailingAnchor)
        ])

        tableScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        tableScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        processesTable.reloadData()
    }

    // MARK: – NSTableViewDataSource
    func numberOfRows(in tableView: NSTableView) -> Int { processBlacklist.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row >= 0 && row < processBlacklist.count else { return nil }
        let value = processBlacklist[row]
        let identifier = NSUserInterfaceItemIdentifier("ProcessCell")

        if let existing = tableView.makeView(
            withIdentifier: identifier, owner: self) as? ProcessCellView {
            existing.field.stringValue = value
            existing.field.delegate = self
            return existing
        }

        let tf = NSTextField(string: value)
        tf.isEditable = true
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.backgroundColor = .clear
        tf.delegate = self
        // No tf.tag: every read of the row index goes through processesTable.row(for:),
        // which stays correct across insertions and cell reuse. A stored tag would not.
        tf.cell?.usesSingleLineMode = true
        tf.cell?.truncatesLastVisibleLine = true
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false

        let cell = ProcessCellView(field: tf)
        cell.identifier = identifier
        // Hard-clip backstop: if the text field somehow exceeds the cell bounds,
        // the layer mask prevents any pixel from rendering outside the row width.
        cell.wantsLayer = true
        cell.layer?.masksToBounds = true
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            tf.heightAnchor.constraint(equalToConstant: 18)
        ])
        return cell
    }

    // MARK: – NSTableViewDelegate
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButtonState()
    }

    // MARK: – NSTextFieldDelegate: editing lifecycle

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField else { return }
        if tf === intervalField { priorIntervalString = tf.stringValue; return }
        tf.drawsBackground = true
        tf.backgroundColor = .textBackgroundColor
        tf.isBordered = false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField else { return }
        let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0

        // --- Interval field ---
        if tf === intervalField {
            InputValidation.validateIntegerField(
                tf, min: 1, max: 3600,
                getCurrent: { Preferences.processKillIntervalSeconds },
                setNew: { Preferences.processKillIntervalSeconds = $0 },
                revertValue: priorIntervalString ?? "\(Preferences.processKillIntervalSeconds)",
                errorMessage: "You must enter a whole number between 1 and 3600.",
                in: self.view)
            return
        }

        // --- Table cell ---
        tf.drawsBackground = false
        tf.backgroundColor = .clear
        tf.isBordered = false

        let row = processesTable.row(for: tf)
        guard row >= 0 && row < processBlacklist.count else { return }

        // Escape → cancel; remove placeholder if still empty.
        if movement == NSTextMovement.cancel.rawValue {
            if processBlacklist.indices.contains(row) &&
               processBlacklist[row].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let w = unsafe self.view.window { w.endEditing(for: nil) }
                processBlacklist.remove(at: row)
                processesTable.reloadData()
                processesTable.deselectAll(nil)
                Task { @MainActor [weak self] in
                    unsafe self?.view.window?.makeFirstResponder(self?.view)
                }
                updateRemoveButtonState()
                persistProcessBlacklistIfChanged()
                lastAddedRow = nil
                self.log("Removed empty placeholder row \(row) via Escape (endEditing first)")
            } else { self.log("Edit canceled on row \(row)") }
            return
        }

        // User cleared the field → remove row.
        let trimmed = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            processBlacklist.remove(at: row)
            processesTable.reloadData()
            processesTable.deselectAll(nil)
            updateRemoveButtonState()
            persistProcessBlacklistIfChanged()
            self.log("Removed empty placeholder row \(row)")
            return
        }

        // No change.
        let prior = processBlacklist[row]
        if trimmed == prior {
            self.log("Blacklisted process row \(row) editing ended — no change")
            return
        }

        // Validate and commit.
        let ok = InputValidation.validateProcessNameField(
            tf, atRow: row, currentList: processBlacklist, priorValue: prior, in: self.view)
        if ok {
            processBlacklist[row] = trimmed
            persistProcessBlacklistIfChanged()
            processesTable.reloadData(
                forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            self.log("Updated blacklisted row \(row) to '\(trimmed)'")

            // Committing a newly added row leaves the table with no selection: AppKit
            // clears it as the field editor tears down, and it does so after this
            // delegate callback returns. The old code re-selected the row here and
            // read the button state back immediately, so it saw a selection that was
            // about to disappear and left "−" enabled with nothing selected.
            //
            // The end state is now made explicit instead of raced for: drop the
            // selection deliberately and derive the button from the table on the next
            // run-loop turn, once AppKit has finished its own teardown.
            if let last = lastAddedRow, last == row {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    unsafe self.view.window?.makeFirstResponder(self.processesTable)
                    self.processesTable.deselectAll(nil)
                    self.updateRemoveButtonState()
                    self.lastAddedRow = nil
                }
            } else {
                // Editing an existing row: the selection is whatever the table says it
                // is once editing has fully ended, so re-derive rather than assume.
                Task { @MainActor [weak self] in
                    self?.updateRemoveButtonState()
                }
            }
        } else {
            // Validation failed; revert visible cell without touching the model.
            processesTable.reloadData(
                forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
    }

    // Intercept Escape through the shared field editor so an empty placeholder
    // is removed even when cancelOperation fires before controlTextDidEndEditing.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if let w = unsafe self.view.window { w.endEditing(for: nil) }
            if control === intervalField { return false }

            if let tf = control as? NSTextField {
                let row = processesTable.row(for: tf)
                if row >= 0 && row < processBlacklist.count {
                    if processBlacklist[row]
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        processBlacklist.remove(at: row)
                        processesTable.reloadData()
                        processesTable.deselectAll(nil)
                        updateRemoveButtonState()
                        persistProcessBlacklistIfChanged()
                        lastAddedRow = nil
                        self.log(
                            "Removed empty placeholder row \(row) via Escape (field-editor intercept)")
                        Task { @MainActor [weak self] in
                            unsafe self?.view.window?.makeFirstResponder(self?.view)
                        }
                        return true
                    }
                }
            }
            return false
        }
        return false
    }

    // MARK: – Actions

    private func updateRemoveButtonState() {
        removeProcessButton.isEnabled = (processesTable.selectedRow >= 0)
    }

    @objc private func addProcess(_ sender: Any?) {
        // Guard: if an empty placeholder row already exists (i.e. a new row is
        // currently awaiting user input), do not add another one.
        if let pendingRow = lastAddedRow,
           processBlacklist.indices.contains(pendingRow),
           processBlacklist[pendingRow]
               .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

        let newIndex = processBlacklist.count
        processBlacklist.append("")
        lastAddedRow = newIndex

        processesTable.beginUpdates()
        processesTable.insertRows(
            at: IndexSet(integer: newIndex), withAnimation: .effectGap)
        processesTable.endUpdates()

        // No reloadData() here: the row is always appended at the end, so no existing
        // row's index moves and insertRows has already put the table in the right state.
        // The reload that used to follow re-rendered every row and discarded the
        // insertion animation it had just been asked for.
        processesTable.selectRowIndexes(
            IndexSet(integer: newIndex), byExtendingSelection: false)

        // insertRows marks the table as needing layout but does not resize it; until
        // that layout pass runs, the scroll view's document rect is still one row short,
        // so scrollRowToVisible has nowhere to scroll to and the new row is only
        // reachable through rubber-band overscroll. Running the pass synchronously here
        // grows the document to include the new row before we scroll to it.
        processesTable.layoutSubtreeIfNeeded()
        tableScrollView.reflectScrolledClipView(tableScrollView.contentView)
        processesTable.scrollRowToVisible(newIndex)

        // Defer first-responder assignment until the row/cell exists in the view.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let cell = self.processesTable.view(
                atColumn: 0, row: newIndex, makeIfNecessary: true) as? ProcessCellView {
                unsafe self.view.window?.makeFirstResponder(cell.field)
            }
            // Begin-editing can shift the scroll position (AppKit scrolls to reveal the
            // field editor's insertion point); re-assert visibility afterwards.
            self.processesTable.scrollRowToVisible(newIndex)
        }
        updateRemoveButtonState()
    }

    @objc private func removeProcess(_ sender: Any?) {
        let selected = processesTable.selectedRowIndexes
        guard !selected.isEmpty else { return }

        let deletedItems = selected.map { processBlacklist[$0] }
        deletedBatchesStack.append((rows: selected, items: deletedItems))

        processBlacklist.remove(atOffsets: selected)
        processesTable.reloadData()
        updateRemoveButtonState()
        persistProcessBlacklistIfChanged()
        self.log("Removed blacklisted process(es): \(deletedItems.joined(separator: ", "))")
    }

    @objc private func undoLastDeletion() {
        guard let batch = deletedBatchesStack.popLast() else { return }
        // Ascending original-index order is what makes this correct on its own: inserting
        // a row back at its own original index shifts every LATER original index back into
        // place by exactly one, so each subsequent insertion finds its index already valid.
        //
        // The running 'offset' that used to be added here double-counted that shift and
        // scattered any non-contiguous batch — {1,3} removed from [a,b,c,d,e] came back as
        // [a,b,c,e,d]. Contiguous selections happened to survive only because the min()
        // clamp absorbed the overshoot, which is why this went unnoticed.
        //
        // The clamp is kept purely as a guard against the list having been mutated between
        // the deletion and the undo (an external preference write, say).
        //
        // batch.items was built by mapping over the selected IndexSet, which iterates in
        // ascending order, so it is already aligned with batch.rows.sorted().
        //
        // An item that is already in the list again (re-added by hand after the deletion,
        // compared case-insensitively like every other duplicate check) is skipped rather
        // than restored, so an undo can never produce a duplicate entry.
        var restoredRows = IndexSet()
        var restoredItems: [String] = []
        for (originalIndex, item) in zip(batch.rows.sorted(), batch.items) {
            let alreadyPresent = processBlacklist.contains {
                $0.caseInsensitiveCompare(item) == .orderedSame }
            if alreadyPresent {
                self.log("Undo last deletion: Skipped '\(item)' — already in the list.")
                continue }
            let index = min(originalIndex, processBlacklist.count)
            processBlacklist.insert(item, at: index)
            restoredRows.insert(index)
            restoredItems.append(item)
        }
        guard !restoredItems.isEmpty else { return }
        processesTable.reloadData()
        processesTable.selectRowIndexes(restoredRows, byExtendingSelection: false)
        processesTable.scrollRowToVisible(restoredRows.first ?? 0)
        updateRemoveButtonState()
        persistProcessBlacklistIfChanged()
        self.log("Undo last deletion: Restored \(restoredItems.joined(separator: ", "))")
    }

    @objc private func resetProcessBlacklistToDefaults(_ sender: Any?) {
        guard let w = unsafe self.view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Reset Blacklist to Defaults"
        alert.informativeText = """
            Are you sure you want to reset the list
            of blacklisted processes to the
            default values?
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: w) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                Preferences.resetProcessBlacklistToDefaults()
                // Deletions made before the reset no longer describe this list.
                self.deletedBatchesStack.removeAll()
                self.processBlacklist = Preferences.blacklistedProcesses
                self.originalProcessBlacklist = processBlacklist
                self.processesTable.reloadData()
                self.processesTable.deselectAll(nil)
                self.updateRemoveButtonState()
                self.log("Blacklisted processes reset to defaults by user")
            } else {
                self.log("User canceled process blacklist reset")
            }
        }
    }

    // MARK: – Keyboard shortcuts
    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch (event.keyCode, cmd) {
        case (51, false):   // Delete
            if removeProcessButton.isEnabled { removeProcess(nil) }
        case (_, true) where event.charactersIgnoringModifiers?.lowercased() == "z":
            undoLastDeletion()
        case (_, true) where event.charactersIgnoringModifiers?.lowercased() == "r":
            resetProcessBlacklistToDefaults(nil)
        case (_, true) where event.charactersIgnoringModifiers?.lowercased() == "n":
            addProcess(nil)
        case (_, true) where event.charactersIgnoringModifiers?.lowercased() == "c":
            copySelectedItems(nil)
        default:
            super.keyDown(with: event)
        }
    }

    private func copySelectedItems(_ sender: Any?) {
        let rows = processesTable.selectedRowIndexes
        guard !rows.isEmpty else { return }
        let items = rows.map { processBlacklist[$0] }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items.joined(separator: "\n"), forType: .string)
        self.log("Copied blacklisted processes: \(items.joined(separator: ", "))")
    }

    // MARK: – Close handling
    // Runs both when the settings window closes and when NSTabViewController
    // navigates away to a different tab (this controller's view remains loaded
    // in memory across tab switches — it is not torn down — so without this,
    // a selection made before switching tabs would still be present, visually
    // un-highlighted, when the user returns, while removeProcessButton stayed
    // enabled from the stale selection and would delete the wrong row.
    // Deselecting here guarantees the table and removeProcessButton are back
    // in a consistent, empty-selection state before this view is ever shown again.
    override func viewWillDisappear() {
        super.viewWillDisappear()
        persistProcessBlacklistIfChanged()
        processesTable.deselectAll(nil)
        updateRemoveButtonState()
    }
}

// MARK: – ProcessCellView
// NSTableCellView.textField is declared unsafe_unretained (`assign`) in the AppKit SDK,
// so every read of it is an unchecked, non-owning access. This subclass holds the field
// strongly in `field`, which is what the rest of the file reads; `textField` is still set,
// once, so that AppKit's own cell behavior (selection text color, accessibility) is
// unchanged. The field is also a subview, so the unretained pointer never outlives it.
final class ProcessCellView: NSTableCellView {
    let field: NSTextField

    init(field: NSTextField) {
        self.field = field
        super.init(frame: .zero)
        addSubview(field)
        unsafe textField = field
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
