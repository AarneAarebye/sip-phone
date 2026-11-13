// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import SwiftUI
import PhoneCore

struct ContactsView: View {
    let core: AppCore
    @State private var query = ""

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
    private var bookLabel: String {
        guard let sel = selection else { return "All phone books" }
        if sel.count == 1, let b = enabledBooks.first(where: { sel.contains($0.id) }) { return b.name }
        return "\(sel.count) phone books"
    }
    private var allOff: Bool { !core.phoneBooks.isEmpty && enabledBooks.isEmpty }
    var body: some View {
        VStack {
            HStack {
                TextField("Search or type a number", text: $query).textFieldStyle(.roundedBorder)
                    .onSubmit { if filtered.isEmpty { Microphone.dial(query, core: core) } }
                if enabledBooks.count >= 2 {
                    Menu(bookLabel) {
                        Button { core.setSelectedPhoneBooks([]) } label: {
                            if selection == nil { Label("All phone books", systemImage: "checkmark") } else { Text("All phone books") }
                        }
                        Divider()
                        ForEach(enabledBooks) { book in
                            Button {
                                core.setSelectedPhoneBooks(PhoneBooks.toggled(book.id, effective: selection, books: core.phoneBooks))
                            } label: {
                                if selection?.contains(book.id) == true { Label(book.name, systemImage: "checkmark") } else { Text(book.name) }
                            }
                        }
                    }.fixedSize()
                }
            }.padding(.horizontal, 8)
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
            }
            }
        }
    }
}
