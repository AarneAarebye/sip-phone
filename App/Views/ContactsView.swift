import SwiftUI
import PhoneCore

struct ContactsView: View {
    let core: AppCore
    @State private var query = ""

    private var filtered: [Contact] {
        query.isEmpty ? core.contacts : core.contacts.filter { ContactFilter.matches($0, query) }
    }
    var body: some View {
        VStack {
            TextField("Search or type a number", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 8)
                .onSubmit { if filtered.isEmpty { Microphone.dial(query, core: core) } }
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
