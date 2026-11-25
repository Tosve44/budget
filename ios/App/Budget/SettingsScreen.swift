import SwiftUI
import UniformTypeIdentifiers
import BudgetKit

struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var exportFile: ExportFile?
    @State private var importing = false
    @State private var pendingImport: Data?
    @State private var message: String?
    @State private var confirmReset = false
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system

    var body: some View {
        NavigationStack {
            let store = model.s
            let syncing = model.sync?.isConnected == true
            Form {
                Section {
                    if !syncing {
                        Picker("This phone belongs to", selection: Binding(get: { store.currentUser.id }, set: { model.store.setCurrentUser($0) })) {
                            ForEach(store.data.users) { u in Text(u.name).tag(u.id) }
                        }
                        .accessibilityIdentifier("whoPicker")
                    } else {
                        LabeledContent("Signed in as", value: store.currentUser.name)
                    }
                    NavigationLink("Names") { NamesScreen() }
                } footer: {
                    Text(syncing ? "Your Personal space is private. The House space is shared."
                                 : "Each person has their own Personal space. The House space is shared once you set up sharing below.")
                }

                Section("Categories and monthly budgets") {
                    if let p = store.personalSpace() {
                        NavigationLink("Personal") { CategoriesScreen(spaceId: p.id) }.accessibilityIdentifier("editPersonalCategories")
                    }
                    if let h = store.houseSpace {
                        NavigationLink("House") { CategoriesScreen(spaceId: h.id) }.accessibilityIdentifier("editHouseCategories")
                    }
                }

                Section {
                    Picker("Look", selection: $appearance) {
                        ForEach(Appearance.allCases) { a in Text(a.title).tag(a) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("appearancePicker")
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Light or dark colours. \"Same as iPhone\" follows your iPhone's setting.")
                }

                PartnerBalanceSection()

                Section {
                    NavigationLink { SharingScreen() } label: {
                        HStack {
                            Text("Share with partner")
                            Spacer()
                            Text(syncStatus).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("sharing")
                }

                Section {
                    Button("Save a backup file") { exportBackup() }.accessibilityIdentifier("exportBackup")
                    Button("Restore from a backup file") { importing = true }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("The backup file works with the web app too. Receipt photos are not included.")
                }

                Section {
                    LabeledContent("Version", value: model.plan == .full ? "Full" : "Free")
                    if model.plan == .free {
                        Text("The free version has \(PlanRules.freePersonalExpenses.count) personal and \(PlanRules.freeHouseExpenses.count) house categories. The full version has all categories and your own.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    #if DEBUG
                    Toggle("Preview the free version", isOn: Binding(get: { model.plan == .free }, set: { model.plan = $0 ? .free : .full }))
                        .accessibilityIdentifier("previewFree")
                    #endif
                } header: {
                    Text("Version")
                } footer: {
                    Text(AppConfig.everyoneHasFullVersion ? "While testing, everyone has the full version for free." : "")
                }

                Section {
                    Button("Start over (delete everything on this phone)", role: .destructive) { confirmReset = true }
                }
            }
            .navigationTitle("Settings")
            .sheet(item: $exportFile) { f in ShareSheet(items: [f.url]) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                guard case .success(let url) = result else { return }
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                pendingImport = try? Data(contentsOf: url)
            }
            .confirmationDialog("Replace everything on this phone with the backup?", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }), titleVisibility: .visible) {
                Button("Replace", role: .destructive) {
                    guard let data = pendingImport else { return }
                    do { try model.store.importJSON(data); message = "Backup restored." } catch { message = error.localizedDescription }
                    pendingImport = nil
                }
            }
            .confirmationDialog("Delete all entries and categories on this phone?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) { model.store.reset() }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") {} }
        }
    }

    var syncStatus: String {
        guard let sync = model.sync else { return "Not set up" }
        switch model.syncState {
        case .off: return "Off"
        case .idle: return sync.pendingCount > 0 ? "Waiting" : "On"
        case .syncing: return "Syncing…"
        case .error: return "Offline"
        }
    }

    func exportBackup() {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("budget-backup-\(DateKey.day()).json")
            try model.store.exportJSON().write(to: url, options: .atomic)
            exportFile = ExportFile(url: url)
        } catch {
            message = "Could not make the backup: \(error.localizedDescription)"
        }
    }
}

struct ExportFile: Identifiable { let url: URL; var id: String { url.absoluteString } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct NamesScreen: View {
    @Environment(AppModel.self) private var model
    @State private var names: [String: String] = [:]

    var body: some View {
        Form {
            ForEach(model.s.data.users) { u in
                TextField("Name", text: Binding(get: { names[u.id] ?? u.name }, set: { names[u.id] = $0 }))
                    .onSubmit { save(u.id) }
            }
        }
        .navigationTitle("Names")
        .onDisappear { for id in names.keys { save(id) } }
    }

    func save(_ id: String) {
        guard let n = names[id]?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return }
        model.store.renameUser(id, to: n)
        if id == model.store.currentUser.id, let sync = model.sync, sync.isConnected { Task { try? await sync.rename(to: n) } }
    }
}

/// The monthly transfer that gives both people the same personal budget.
struct PartnerBalanceSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.s
        let month = DateKey.month()
        Section {
            if let t = store.suggestedPartnerTransfer(month: month), let from = store.user(t.fromUserId), let to = store.user(t.toUserId) {
                Text("\(from.name) sends \(to.name) \(model.money(t.amount)) this month, so both have the same personal money.")
                    .accessibilityIdentifier("partnerBalanceText")
            } else {
                Text("Add both people's income (Salary) in their Personal space to see how much to send.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Partner balance")
        } footer: {
            Text("Based on this month's personal income on this phone. Record the transfer as a \"Partner balance\" expense.")
        }
    }
}

struct CategoriesScreen: View {
    @Environment(AppModel.self) private var model
    let spaceId: String
    @State private var editing: CategorySheet?

    enum CategorySheet: Identifiable {
        case new(EntryKind), edit(EntryCategory)
        var id: String { switch self { case .new(let k): return "new-\(k)"; case .edit(let c): return c.id } }
    }

    var body: some View {
        let store = model.s
        List {
            ForEach(EntryKind.allCases, id: \.self) { kind in
                let cats = store.categories(in: spaceId, includeArchived: true, kind: kind)
                Section(kind == .expense ? "Expenses" : "Income") {
                    ForEach(cats) { c in
                        Button { editing = .edit(c) } label: {
                            HStack {
                                Text(c.name).foregroundStyle(c.archived ? Color.secondary : Color.primary)
                                if c.archived { Text("hidden").font(.caption).foregroundStyle(.secondary) }
                                if !PlanRules.isAvailable(c, in: store.space(spaceId), plan: model.plan) {
                                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if c.kind == .expense { Text(c.budget > 0 ? model.money(c.budget) : "no budget").foregroundStyle(.secondary) }
                            }
                            .contentShape(Rectangle()) // the whole row reacts, not only the text
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("categoryRow.\(c.name)")
                    }
                    .onMove { from, to in
                        var ids = cats.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        model.store.reorderCategories(in: spaceId, kind: kind, ids: ids)
                    }
                    if PlanRules.canAddCustomCategory(plan: model.plan) {
                        Button { editing = .new(kind) } label: { Label("Add category", systemImage: "plus") }
                            .accessibilityIdentifier("addCategory.\(kind.rawValue)")
                    }
                }
            }
        }
        .toolbar { EditButton() }
        .navigationTitle(store.space(spaceId)?.type == .house ? "House categories" : "Personal categories")
        .sheet(item: $editing) { sheet in
            switch sheet {
            case .new(let k): CategoryEditor(spaceId: spaceId, kind: k, category: nil)
            case .edit(let c): CategoryEditor(spaceId: spaceId, kind: c.kind, category: c)
            }
        }
    }
}

struct CategoryEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let spaceId: String
    let kind: EntryKind
    let category: EntryCategory?
    @State private var name = ""
    @State private var budgetText = ""
    @State private var problem: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name, e.g. Pets", text: $name)
                    .focused($nameFocused)
                    .disabled(category != nil && !PlanRules.canRenameCategory(plan: model.plan))
                    .accessibilityIdentifier("categoryName")
                if kind == .expense {
                    Section {
                        TextField("Monthly budget (empty for none)", text: $budgetText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("categoryBudget")
                    } footer: {
                        Text("How much you plan to spend in this category each month.")
                    }
                }
                if let problem { Text(problem).foregroundStyle(.red).accessibilityIdentifier("categoryProblem") }
                if let c = category {
                    Section {
                        Button(c.archived ? "Show again" : "Hide category") {
                            model.store.updateCategory(c.id, archived: !c.archived)
                            dismiss()
                        }
                        .accessibilityIdentifier("toggleHidden")
                    } footer: {
                        Text("Hiding keeps past entries but removes the category from lists and the add screen.")
                    }
                }
            }
            .navigationTitle(category == nil ? "New category" : "Edit category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).accessibilityIdentifier("saveCategory") }
            }
            .onAppear {
                name = category?.name ?? ""
                budgetText = Money.inputText(category?.budget ?? 0)
                if category == nil { nameFocused = true }
            }
        }
    }

    func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { problem = "Enter a name."; return }
        guard !model.store.categoryNameTaken(n, spaceId: spaceId, kind: kind, excluding: category?.id) else {
            problem = "There is already a category called \"\(n)\"."; return
        }
        guard n.unicodeScalars.count <= Limits.categoryName else { problem = "The name is too long (at most \(Limits.categoryName) characters)."; return }
        let trimmed = budgetText.trimmingCharacters(in: .whitespaces)
        let budget = trimmed.isEmpty ? 0 : Money.cents(trimmed)
        guard let budget, budget >= 0 else { problem = "The budget must be a number."; return }
        guard budget <= Limits.maxCents else { problem = "That budget is too big."; return }
        if let c = category {
            model.store.updateCategory(c.id, name: n, budget: kind == .expense ? budget : nil)
        } else {
            model.store.addCategory(spaceId: spaceId, name: n, kind: kind, budget: kind == .expense ? budget : 0)
        }
        dismiss()
    }
}
