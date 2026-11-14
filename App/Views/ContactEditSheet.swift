// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import SwiftUI
import PhoneCore

/// Name plus a list of numbers (add/remove rows, type picker). `onSave` returns true when the box accepted the change.
struct ContactEditSheet: View {
    struct Row: Identifiable { let id = UUID(); var number: String; var type: PhoneNumberType }

    let title: String
    let bookName: String
    let error: String?
    let onSave: (ContactDraft) async -> Bool
    let onCancel: () -> Void

    @State private var name: String
    @State private var rows: [Row]
    @State private var localError: String?
    @State private var saving = false

    init(title: String, bookName: String, initial: ContactDraft, error: String?,
         onSave: @escaping (ContactDraft) async -> Bool, onCancel: @escaping () -> Void) {
        self.title = title; self.bookName = bookName; self.error = error; self.onSave = onSave; self.onCancel = onCancel
        _name = State(initialValue: initial.name)
        let initialRows = initial.numbers.map { Row(number: $0.number, type: PhoneNumberType.from($0.type)) }
        _rows = State(initialValue: initialRows.isEmpty ? [Row(number: "", type: .home)] : initialRows)
    }

    private var draft: ContactDraft {
        ContactDraft(name: name, numbers: rows.map { PhoneNumber(number: $0.number, type: $0.type.rawValue) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Label(bookName, systemImage: "book").font(.caption).foregroundStyle(.secondary)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            ForEach($rows) { $row in
                HStack {
                    Picker("Type", selection: $row.type) {
                        ForEach(PhoneNumberType.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 90)
                    TextField("Number", text: $row.number).textFieldStyle(.roundedBorder)
                    Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).disabled(rows.count <= 1).help("Remove this number")
                }
            }
            Button { rows.append(Row(number: "", type: .mobile)) } label: { Label("Add number", systemImage: "plus.circle") }
                .buttonStyle(.link)
            if let message = localError ?? error {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save") {
                    if let e = draft.validationError { localError = e; return }
                    localError = nil; saving = true
                    Task { _ = await onSave(draft.cleaned); saving = false }
                }.keyboardShortcut(.defaultAction).disabled(saving)
            }
        }
        .padding(16).frame(width: 380)
    }
}
