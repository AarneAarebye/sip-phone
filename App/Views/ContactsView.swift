// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 SIP Phone contributors

import SwiftUI
import PhoneCore

struct ContactsView: View {
    let core: AppCore
    @State private var query = ""

    @State private var selectedBook: String?   // nil = all phone books

    private var enabledBooks: [PhoneBookSummary] {
        core.phoneBooks.filter { !core.settings.disabledPhoneBooks.contains($0.id) }
    }
    /// The selection, or nil when that book vanished or was switched off.
    private var activeBook: String? { enabledBooks.contains { $0.id == selectedBook } ? selectedBook : nil }
    private var filtered: [Contact] {
        PhoneBooks.filter(core.visibleContacts, bookID: activeBook, query: query)
    }
    private var allOff: Bool { !core.phoneBooks.isEmpty && enabledBooks.isEmpty }
    var body: some View {
        VStack {
            HStack {
                TextField("Search or type a number", text: $query).textFieldStyle(.roundedBorder)
                    .onSubmit { if filtered.isEmpty { Microphone.dial(query, core: core) } }
                if enabledBooks.count >= 2 {
                    Picker("Phone book", selection: Binding(get: { activeBook }, set: { selectedBook = $0 })) {
                        Text("All phone books").tag(String?.none)
                        ForEach(enabledBooks) { Text($0.name).tag(Optional($0.id)) }
                    }.labelsHidden().fixedSize()
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
