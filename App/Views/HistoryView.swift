// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhoneCore

struct HistoryView: View {
    let core: AppCore
    @State private var query = ""
    @State private var from: Date?
    @State private var to: Date?
    @State private var selection = Set<Int>()
    @State private var exportError: String?

    private var area: String? { core.settings.areaCode.isEmpty ? nil : core.settings.areaCode }
    private var filtered: [CallRecord] {
        CallLogFilter.filter(core.history, query: query, from: from, to: to,
                             countryCode: core.settings.countryCode, areaCode: area)
    }
    /// Selected entries (in list order), or everything currently shown when nothing is selected.
    private var exportRows: [CallRecord] {
        selection.isEmpty ? filtered : filtered.filter { selection.contains($0.id) }
    }
    private var filterActive: Bool { !query.isEmpty || from != nil || to != nil }

    var body: some View {
        VStack {
            TextField("Filter by name or number", text: $query).textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
            HStack(spacing: 8) {
                Menu("Period") {
                    ForEach(CallLogRangePreset.allCases, id: \.self) { p in
                        Button(title(p)) { let r = p.range(); from = r.from; to = r.to }
                    }
                }.fixedSize()
                Spacer(minLength: 0)
                if filterActive { Button("Clear") { query = ""; from = nil; to = nil } }
                ExportCSVButton(help: selection.isEmpty ? "Export filtered calls as CSV…" : "Export selected calls as CSV…",
                                disabled: exportRows.isEmpty) { exportCSV() }
            }.padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Toggle("From", isOn: Binding(get: { from != nil }, set: { from = $0 ? Calendar.current.startOfDay(for: Date()) : nil }))
                    Spacer(minLength: 0)
                    if let f = from {
                        DatePicker("", selection: Binding(get: { f }, set: { from = $0 }), displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                    }
                }
                HStack {
                    Toggle("To", isOn: Binding(get: { to != nil }, set: { to = $0 ? Date() : nil }))
                    Spacer(minLength: 0)
                    if let t = to {
                        DatePicker("", selection: Binding(get: { t }, set: { to = $0 }), displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                    }
                }
            }.font(.caption).padding(.horizontal, 12)
            List(filtered, selection: $selection) { r in
                HStack {
                    Image(systemName: icon(r.type)).foregroundStyle(r.type == .missed ? .red : .secondary)
                    VStack(alignment: .leading) {
                        Text(r.name ?? r.remoteNumber).font(.headline)
                        Text(r.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(CallDuration.format(r.duration) ?? "—").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button { Microphone.dial(r.remoteNumber, core: core) } label: { Image(systemName: "phone") }.buttonStyle(.borderless)
                }
            }
            if let exportError { Text(exportError).font(.caption).foregroundStyle(.red) }
        }
        .task { await core.refreshHistory() }
    }

    private func title(_ p: CallLogRangePreset) -> String {
        switch p { case .all: "All"; case .today: "Today"; case .last7Days: "Last 7 days"; case .last30Days: "Last 30 days" }
    }

    private func exportCSV() {
        let rows = exportRows
        let books = CallLogCSV.phoneBooks(for: rows, contacts: core.contacts,
                                          countryCode: core.settings.countryCode, areaCode: area)
        let csv = CallLogCSV.build(rows, phoneBook: books)
        guard let url = chooseCSVSaveURL(fileName: CallLogCSV.defaultFileName()) else { return }
        do { try csv.write(to: url, atomically: true, encoding: .utf8); exportError = nil }
        catch { exportError = "Export failed: \(error.localizedDescription)" }
    }

    private func icon(_ t: CallRecordType) -> String {
        switch t {
        case .incoming: "phone.arrow.down.left"; case .missed: "phone.down"
        case .outgoing: "phone.arrow.up.right"; case .rejected: "phone.down.circle"
        }
    }
}
