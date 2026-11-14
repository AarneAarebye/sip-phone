// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhoneCore

struct ContactsView: View {
    let core: AppCore
    @State private var query = ""
    private enum Sheet: Identifiable {
        case add(PhoneBookSummary), edit(Contact)
        var id: String { switch self { case .add(let b): "add-\(b.id)"; case .edit(let c): "edit-\(c.id)" } }
    }
    private struct Transfer: Identifiable { let contact: Contact; let target: PhoneBookSummary; let mode: TransferMode; var id: String { contact.id + target.id } }
    @State private var sheet: Sheet?
    @State private var deleting: Contact?
    @State private var transfer: Transfer?
    @State private var busy = false

    private var writableBooks: [PhoneBookSummary] { enabledBooks.filter { !$0.readOnly } }

    private var enabledBooks: [PhoneBookSummary] {
        core.phoneBooks.filter { !core.settings.disabledPhoneBooks.contains($0.id) }
    }
    /// nil = all enabled books.
    private var selection: Set<String>? {
        PhoneBooks.effectiveSelection(stored: core.settings.selectedPhoneBooks, books: core.phoneBooks,
                                      disabled: core.settings.disabledPhoneBooks)
    }
    private var filtered: [Contact] {
        PhoneBooks.filter(core.visibleContacts, bookIDs: selection, query: query)
    }
    /// Everything in the selected books; the search text is ignored.
    private var exportContacts: [Contact] {
        PhoneBooks.filter(core.visibleContacts, bookIDs: selection, query: "")
    }
    private var bookLabel: String {
        guard let sel = selection else { return "All phone books" }
        if sel.count == 1, let b = enabledBooks.first(where: { sel.contains($0.id) }) { return b.name }
        return "\(sel.count) phone books"
    }
    private var allOff: Bool { !core.phoneBooks.isEmpty && enabledBooks.isEmpty }
    var body: some View {
        content
    }

    private var content: some View {
        VStack {
            TextField("Search or type a number", text: $query).textFieldStyle(.roundedBorder)
                .onSubmit { if filtered.isEmpty { Microphone.dial(query, core: core) } }
                .padding(.horizontal, 12)
            HStack(spacing: 8) {
                if enabledBooks.count >= 2 {
                    Menu(bookLabel) {
                        // Toggles, not Buttons: a menu draws the native checkmark for a Toggle, but drops the image of a Button label.
                        Toggle("All phone books", isOn: Binding(
                            get: { selection == nil },
                            set: { _ in core.setSelectedPhoneBooks([]) }))
                        Divider()
                        ForEach(enabledBooks) { book in
                            Toggle(book.name, isOn: Binding(
                                get: { selection?.contains(book.id) == true },
                                set: { _ in core.setSelectedPhoneBooks(PhoneBooks.toggled(book.id, effective: selection, books: core.phoneBooks)) }))
                        }
                    }.lineLimit(1).truncationMode(.tail).frame(maxWidth: 190, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                }
                Spacer(minLength: 0)
                Button { exportSelection() } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Export CSV…")
                    .help("Export the contacts of the selected phone books as a CSV file")
                    .disabled(exportContacts.isEmpty)
                if core.canEditPhoneBooks, !writableBooks.isEmpty {
                    if writableBooks.count == 1, let only = writableBooks.first {
                        Button { start { sheet = .add(only) } } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Add contact").help("Add contact")
                    } else {
                        Menu { ForEach(writableBooks) { b in Button(b.name) { start { sheet = .add(b) } } } }
                            label: { Image(systemName: "plus") }.menuIndicator(.hidden).accessibilityLabel("Add contact").help("Add contact").fixedSize()
                    }
                }
            }.padding(.horizontal, 12)
            if let e = core.editError, sheet == nil {
                Text(e).font(.caption).foregroundStyle(.red).padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            if allOff {
                Text("All phone books are switched off — turn them on in Settings.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            List(filtered) { c in
                VStack(alignment: .leading) {
                    Text(c.name.isEmpty ? (c.numbers.first?.number ?? "—") : c.name).font(.headline)
                    if let book = c.phoneBook {
                        Label(book, systemImage: "book").font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(c.numbers, id: \.number) { n in
                        Button { Microphone.dial(n.number, core: core) } label: {
                            Label("\(n.type) \(n.number)", systemImage: "phone").font(.caption)
                        }.buttonStyle(.link)
                    }
                }
                .contextMenu { menu(for: c) }
            }
            }
        }
        .disabled(busy)
        .sheet(item: $sheet) { which in
            switch which {
            case .add(let book):
                ContactEditSheet(title: "Add contact", bookName: book.name, initial: ContactDraft(name: "", numbers: []),
                                 error: core.editError, onSave: { draft in
                    await write(bookID: book.id, bookName: book.name) { await core.addContact(bookID: book.id, draft: draft) }
                }, onCancel: { sheet = nil })
            case .edit(let c):
                ContactEditSheet(title: "Edit contact", bookName: c.phoneBook ?? "", initial: ContactDraft(c),
                                 error: core.editError, onSave: { draft in
                    await write(bookID: c.bookID ?? "", bookName: c.phoneBook ?? "") { await core.updateContact(c, draft: draft) }
                }, onCancel: { sheet = nil })
            }
        }
        .confirmationDialog("Delete this contact?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { c in
            Button("Delete \(c.name.isEmpty ? "contact" : c.name)", role: .destructive) {
                Task { await write(bookID: c.bookID ?? "", bookName: c.phoneBook ?? "") { await core.deleteContact(c) } }
            }
        } message: { c in
            Text("\(c.name.isEmpty ? "The contact" : c.name) will be removed from the phone book \"\(c.phoneBook ?? "")\" on the FRITZ!Box.")
        }
        .confirmationDialog(transfer?.mode == .move ? "Move this contact?" : "Copy this contact?",
                            isPresented: Binding(get: { transfer != nil }, set: { if !$0 { transfer = nil } }), presenting: transfer) { t in
            Button(t.mode == .move ? "Move to \(t.target.name)" : "Copy to \(t.target.name)") {
                Task {
                    await write(bookID: t.contact.bookID ?? "", bookName: t.contact.phoneBook ?? "") {
                        await core.transferContact(t.contact, toBook: t.target.id, mode: t.mode)
                    }
                }
            }
        } message: { t in
            Text(t.mode == .move
                 ? "It is created in \"\(t.target.name)\" first and only then removed from \"\(t.contact.phoneBook ?? "")\"."
                 : "A copy is created in \"\(t.target.name)\"; the original stays.")
        }
    }

    // MARK: Row menu

    @ViewBuilder private func menu(for c: Contact) -> some View {
        if core.canEditPhoneBooks, TransferTargets.canEdit(c) {
            Button("Edit…") { start { sheet = .edit(c) } }
            let targets = TransferTargets.targets(for: c, books: core.phoneBooks, disabled: core.settings.disabledPhoneBooks)
            if !targets.isEmpty {
                Menu("Move to") { ForEach(targets) { b in Button(b.name) { start { transfer = Transfer(contact: c, target: b, mode: .move) } } } }
                Menu("Copy to") { ForEach(targets) { b in Button(b.name) { start { transfer = Transfer(contact: c, target: b, mode: .copy) } } } }
            }
            Divider()
            Button("Delete…", role: .destructive) { start { deleting = c } }
        } else if core.canEditPhoneBooks, c.phoneBookReadOnly {
            Text("Read-only phone book")
            let targets = TransferTargets.targets(for: c, books: core.phoneBooks, disabled: core.settings.disabledPhoneBooks)
            if !targets.isEmpty, !(c.entryID ?? "").isEmpty {
                Menu("Copy to") { ForEach(targets) { b in Button(b.name) { start { transfer = Transfer(contact: c, target: b, mode: .copy) } } } }
            }
        }
    }

    private func start(_ action: () -> Void) { core.clearEditError(); action() }

    // MARK: Writing with backup

    /// Offers a CSV backup before the first write to a book in this session, then runs `op`; closes the sheet on success.
    private func write(bookID: String, bookName: String, _ op: () async -> Bool) async -> Bool {
        if core.needsBackup(bookID: bookID), !bookID.isEmpty {
            switch backupChoice(bookID: bookID, bookName: bookName) {
            case .cancel: return false
            case .proceed: core.markBackedUp(bookID: bookID)
            }
        }
        busy = true
        let ok = await op()
        busy = false
        if ok { sheet = nil; deleting = nil; transfer = nil }
        return ok
    }

    private enum BackupChoice { case proceed, cancel }

    private func backupChoice(bookID: String, bookName: String) -> BackupChoice {
        let alert = NSAlert()
        alert.messageText = "Back up \"\(bookName)\" before changing it?"
        alert.informativeText = "Changes are written to the FRITZ!Box straight away. A CSV file of this phone book lets you restore it by hand. This is asked once per phone book and session."
        alert.addButton(withTitle: "Back up…")
        alert.addButton(withTitle: "Continue without backup")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveCSV(core.contacts(inBook: bookID), fileName: ContactCSV.defaultFileName(book: bookName)) ? .proceed : .cancel
        case .alertSecondButtonReturn: return .proceed
        default: return .cancel
        }
    }

    // MARK: Export

    private func exportSelection() { _ = saveCSV(exportContacts, fileName: ContactCSV.exportFileName()) }

    /// Shared by the export button and the backup before the first write. Returns false when cancelled or failed.
    private func saveCSV(_ contacts: [Contact], fileName: String) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = fileName
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do { try ContactCSV.build(contacts).write(to: url, atomically: true, encoding: .utf8); return true }
        catch {
            let fail = NSAlert()
            fail.messageText = "Export failed"; fail.informativeText = error.localizedDescription
            fail.runModal(); return false
        }
    }
}
