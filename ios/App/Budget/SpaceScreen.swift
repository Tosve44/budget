import SwiftUI
import BudgetKit

/// One space (your Personal space, or the shared House space) for one month:
/// what is left of the budget, spending per category and all entries.
struct SpaceScreen: View {
    @Environment(AppModel.self) private var model
    let spaceType: SpaceType
    @State private var month = DateKey.month()
    @State private var filterCategoryId: String?
    @State private var sheet: EntrySheet?

    var space: Space? {
        spaceType == .house ? model.s.houseSpace : model.s.personalSpace()
    }

    var body: some View {
        NavigationStack {
            Group {
                if let space {
                    content(space)
                } else {
                    ContentUnavailableView("No space", systemImage: "questionmark.folder")
                }
            }
            .navigationTitle(spaceType == .house ? "House" : "Personal")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { if let space { sheet = .new(spaceId: space.id) } } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                    .accessibilityLabel("Add entry")
                    .accessibilityIdentifier("addEntry")
                }
            }
            .sheet(item: $sheet) { s in
                EntryEditor(sheet: s, defaultDate: defaultDate)
            }
        }
    }

    /// New entries get today's date, or the 1st when looking at another month.
    var defaultDate: String { month == DateKey.month() ? DateKey.day() : "\(month)-01" }

    @ViewBuilder
    func content(_ space: Space) -> some View {
        let store = model.s
        let sum = store.monthSummary(spaceId: space.id, month: month)
        let expenseCats = store.categories(in: space.id, kind: .expense)
        let incomeCats = store.categories(in: space.id, kind: .income)
        // Only categories with a budget or activity this month, to keep the list short.
        let activeExpense = expenseCats.filter { $0.budget > 0 || sum.byCategory[$0.id] != nil }
        let activeIncome = incomeCats.filter { sum.byCategory[$0.id] != nil }
        let entries = store.transactions(in: space.id, month: month).filter { filterCategoryId == nil || $0.categoryId == filterCategoryId }

        List {
            Section {
                MonthSwitcher(month: $month)
                SummaryCard(sum: sum) { kind in sheet = .new(spaceId: space.id, kind: kind) }
            }
            Section("Spending by category") {
                if activeExpense.isEmpty {
                    Text("Nothing spent yet this month.").foregroundStyle(.secondary)
                }
                ForEach(activeExpense) { c in
                    categoryRow(c, spent: sum.byCategory[c.id] ?? 0)
                }
            }
            if !activeIncome.isEmpty {
                Section("Income") {
                    ForEach(activeIncome) { c in categoryRow(c, spent: sum.byCategory[c.id] ?? 0) }
                }
            }
            Section {
                if let f = filterCategoryId, let c = store.category(f) {
                    Button { filterCategoryId = nil } label: {
                        Label("Showing \(c.name) only", systemImage: "xmark.circle.fill")
                    }
                    .accessibilityIdentifier("clearFilter")
                }
                if entries.isEmpty {
                    Text("No entries yet. Tap + to add one.").foregroundStyle(.secondary)
                }
                ForEach(entries) { t in
                    Button { sheet = .edit(t) } label: { EntryRow(entry: t, showWho: space.type == .house).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { model.store.deleteTransaction(t.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            } header: {
                Text(filterCategoryId == nil ? "All entries" : "Entries")
            }
        }
        .refreshable { model.syncIfConnected() }
        .accessibilityIdentifier("spaceList")
    }

    func categoryRow(_ c: EntryCategory, spent: Int) -> some View {
        Button {
            filterCategoryId = filterCategoryId == c.id ? nil : c.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(c.name)
                    Spacer()
                    if c.kind == .expense && c.budget > 0 {
                        Text("\(model.money(spent)) / \(model.money(c.budget))").monospacedDigit()
                    } else {
                        Text(model.money(spent)).monospacedDigit()
                    }
                }
                if c.kind == .expense && c.budget > 0 {
                    BudgetBar(spent: spent, budget: c.budget)
                }
            }
            .contentShape(Rectangle()) // the whole row reacts, not only the text
        }
        .buttonStyle(.plain)
        .listRowBackground(filterCategoryId == c.id ? Color.accentColor.opacity(0.12) : nil)
        .accessibilityIdentifier("category.\(c.name)")
    }
}

enum EntrySheet: Identifiable {
    case new(spaceId: String, kind: EntryKind = .expense)
    case edit(Entry)
    var id: String {
        switch self {
        case .new(let sp, let kind): return "new-\(sp)-\(kind.rawValue)"
        case .edit(let t): return t.id
        }
    }
}

struct MonthSwitcher: View {
    @Binding var month: String

    var body: some View {
        HStack {
            Button { month = DateKey.shift(month: month, by: -1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous month").accessibilityIdentifier("prevMonth")
            Spacer()
            Text(MonthSwitcher.title(month)).font(.headline).accessibilityIdentifier("monthTitle")
            Spacer()
            Button { month = DateKey.shift(month: month, by: 1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next month").accessibilityIdentifier("nextMonth")
        }
        .buttonStyle(.borderless)
    }

    static func title(_ month: String) -> String {
        guard let d = DateKey.date(fromDay: month + "-01") else { return month }
        return d.formatted(.dateTime.month(.wide).year())
    }
}

struct SummaryCard: View {
    @Environment(AppModel.self) private var model
    let sum: MonthSummary
    /// Tapping Income or Spent opens the add screen for that kind of entry.
    var onAdd: (EntryKind) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if sum.budget > 0 {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading) {
                        Text(sum.left >= 0 ? "Left this month" : "Over budget").font(.subheadline).foregroundStyle(.secondary)
                        Text(model.money(abs(sum.left)))
                            .font(.largeTitle.bold()).monospacedDigit()
                            .foregroundStyle(sum.left < 0 ? Color.red : Color.primary)
                            .accessibilityIdentifier("leftAmount")
                    }
                    Spacer()
                    Text("\(Int((Double(sum.spent) / Double(sum.budget) * 100).rounded()))% of \(model.money(sum.budget))")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("budgetUsed")
                }
                BudgetBar(spent: sum.spent, budget: sum.budget)
            } else {
                Text("Spent this month").font(.subheadline).foregroundStyle(.secondary)
                Text(model.money(sum.spent)).font(.largeTitle.bold()).monospacedDigit().accessibilityIdentifier("spentAmount")
                Text("No monthly budget set yet. Add one per category in Settings.").font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                addButton(.income, "Income", model.money(sum.income), Color.green)
                addButton(.expense, "Spent", model.money(sum.spent), Color.primary)
            }
            let balance = sum.income - sum.spent
            HStack {
                Text("Balance").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text((balance > 0 ? "+" : balance < 0 ? "−" : "") + model.money(abs(balance)))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(balance < 0 ? Color.red : Color.primary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("balance")
        }
        .padding(.vertical, 4)
    }

    /// Borderless, so each one reacts on its own inside the list row.
    func addButton(_ kind: EntryKind, _ label: String, _ value: String, _ color: Color) -> some View {
        Button { onAdd(kind) } label: {
            HStack(spacing: 2) {
                stat(label, value, color)
                Image(systemName: "plus.circle").font(.caption).foregroundStyle(.tint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityHint(kind == .income ? "Adds income" : "Adds an expense")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(kind == .income ? "addIncome" : "addExpense")
    }

    func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(color)
                .accessibilityIdentifier("stat.\(label)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BudgetBar: View {
    let spent: Int
    let budget: Int

    var body: some View {
        let fraction = budget > 0 ? min(1, Double(spent) / Double(budget)) : 0
        let color: Color = spent > budget ? .red : fraction > 0.85 ? .orange : .accentColor
        ProgressView(value: fraction).tint(color)
    }
}

struct EntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: Entry
    let showWho: Bool

    var body: some View {
        let store = model.s
        let meta = [
            DateKey.date(fromDay: entry.date)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
            (entry.items?.isEmpty == false) ? "🧾 \(entry.items!.count) items" : (entry.receiptId != nil ? "🧾" : nil),
            entry.note.isEmpty ? nil : entry.note,
            showWho ? store.user(entry.createdBy)?.name : nil,
        ].compactMap { $0 }.joined(separator: " · ")
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.category(entry.categoryId)?.name ?? "Deleted category")
                Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text((entry.kind == .income ? "+" : "−") + model.money(entry.amount))
                .monospacedDigit()
                .foregroundStyle(entry.kind == .income ? Color.green : Color.primary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("entry")
    }
}
