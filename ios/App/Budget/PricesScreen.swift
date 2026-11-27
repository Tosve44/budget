import SwiftUI
import Charts
import BudgetKit

/// Every item from your receipts with its price over time (grocery price inflation).
struct PricesScreen: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        NavigationStack {
            let groups = PriceHistory.list(model.s.data.transactions, search: search)
            List {
                if groups.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No items yet" : "No matches",
                                           systemImage: "cart",
                                           description: Text(search.isEmpty ? "Scan a receipt when adding an expense, and its items show up here." : "Try another word."))
                }
                ForEach(groups) { g in
                    NavigationLink { PriceDetail(group: g) } label: { PriceRow(group: g) }
                        .accessibilityIdentifier("priceRow")
                }
            }
            .searchable(text: $search, prompt: "Search items")
            .navigationTitle("Prices")
        }
    }
}

struct PriceRow: View {
    @Environment(AppModel.self) private var model
    let group: PriceHistory.Group

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                Text("\(group.entries.count)× · last \(ComparisonBadge.day(group.latest.date))"
                     + (group.previous.map { " · before \(model.money($0.price))" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if group.entries.count > 1 {
                Chart(Array(group.entries.enumerated()), id: \.offset) { item in
                    LineMark(x: .value("n", item.offset), y: .value("price", item.element.price))
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(width: 56, height: 24)
                .accessibilityHidden(true)
            }
            VStack(alignment: .trailing) {
                Text(model.money(group.latest.price)).monospacedDigit()
                ChangeBadge(percent: group.changeSinceFirst, single: group.entries.count == 1)
            }
        }
    }
}

struct ChangeBadge: View {
    let percent: Double?
    let single: Bool

    var body: some View {
        let (text, color): (String, Color) = {
            if single || percent == nil { return ("new", .secondary) }
            if percent == 0 { return ("same", .secondary) }
            let p = ComparisonBadge.pct(percent!)
            return percent! > 0 ? ("▲ +\(p)%", .red) : ("▼ \(p)%", .green)
        }()
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
    }
}

struct PriceDetail: View {
    @Environment(AppModel.self) private var model
    let group: PriceHistory.Group

    var body: some View {
        List {
            if group.entries.count > 1 {
                Section {
                    Chart(group.entries, id: \.txId) { e in
                        LineMark(x: .value("Date", DateKey.date(fromDay: e.date) ?? Date()), y: .value("Price", Double(e.price) / 100))
                        PointMark(x: .value("Date", DateKey.date(fromDay: e.date) ?? Date()), y: .value("Price", Double(e.price) / 100))
                    }
                    .frame(height: 180)
                    if let pct = group.changeSinceFirst {
                        Text("Since the first purchase: \(pct > 0 ? "+" : "")\(ComparisonBadge.pct(pct))%")
                    }
                }
            }
            Section("History") {
                ForEach(group.entries.reversed(), id: \.txId) { e in
                    HStack {
                        Text(DateKey.date(fromDay: e.date)?.formatted(date: .abbreviated, time: .omitted) ?? e.date)
                        Spacer()
                        Text(model.money(e.price)).monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
