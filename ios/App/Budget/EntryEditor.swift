import SwiftUI
import PhotosUI
import BudgetKit

/// Add or change an entry. A receipt photo fills in the items and the total.
struct EntryEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EntryDraft
    @State private var problem: String?
    @State private var showScanner = false
    @State private var photoItem: PhotosPickerItem?
    @State private var reading = false
    @State private var readNote: String?
    @State private var confirmDelete = false
    @State private var savedAsNew = false
    @FocusState private var amountFocused: Bool
    let isNew: Bool

    init(sheet: EntrySheet, defaultDate: String) {
        switch sheet {
        case .new(let spaceId, let kind):
            _draft = State(initialValue: EntryDraft(spaceId: spaceId, kind: kind, date: defaultDate))
            isNew = true
        case .edit(let t):
            _draft = State(initialValue: EntryDraft(editing: t))
            isNew = false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $draft.kind) {
                        Text("Expense").tag(EntryKind.expense)
                        Text("Income").tag(EntryKind.income)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("kindPicker")
                    .onChange(of: draft.kind) { _, _ in
                        if let c = draft.categoryId, model.s.category(c)?.kind != draft.kind { draft.categoryId = nil }
                    }
                    HStack {
                        TextField("0,00", text: $draft.amountText)
                            .keyboardType(.decimalPad)
                            .font(.title.bold())
                            .focused($amountFocused)
                            .accessibilityIdentifier("amountField")
                        Text(model.currency).foregroundStyle(.secondary)
                    }
                    Picker("Category", selection: $draft.categoryId) {
                        Text("Pick one").tag(String?.none)
                        ForEach(categories) { c in Text(c.name).tag(Optional(c.id)) }
                    }
                    .accessibilityIdentifier("categoryPicker")
                    DatePicker("Date", selection: dateBinding, displayedComponents: .date)
                    TextField("Note (optional)", text: $draft.note)
                        .accessibilityIdentifier("noteField")
                }
                if draft.kind == .expense { receiptSection }
                if let problem {
                    Section { Text(problem).foregroundStyle(.red).accessibilityIdentifier("formProblem") }
                }
                if !isNew {
                    Section {
                        Button("Delete entry", role: .destructive) { confirmDelete = true }
                            .accessibilityIdentifier("deleteEntry")
                    }
                }
            }
            .navigationTitle(isNew ? (draft.kind == .income ? "New income" : "New expense") : "Edit entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).bold().accessibilityIdentifier("saveEntry")
                }
            }
            .alert("Saved as a new entry", isPresented: $savedAsNew) {
                Button("OK") { dismiss() }
            } message: {
                Text("This entry was deleted on the other phone while you were changing it, so your version was added again.")
            }
            .confirmationDialog("Delete this entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let id = draft.existingId { model.store.deleteTransaction(id) }
                    dismiss()
                }
            }
            .onAppear { if isNew { amountFocused = true } }
            .fullScreenCover(isPresented: $showScanner) {
                ReceiptScanner { image in
                    showScanner = false
                    if let image { Task { await read(image) } }
                }
                .ignoresSafeArea()
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { await read(img) }
                    photoItem = nil
                }
            }
        }
    }

    var categories: [EntryCategory] {
        var list = model.s.pickableCategories(in: draft.spaceId, kind: draft.kind, plan: model.plan)
        // When editing, keep showing the entry's category even if it is hidden now.
        if let id = draft.categoryId, !list.contains(where: { $0.id == id }), let c = model.s.category(id) { list.insert(c, at: 0) }
        return list
    }

    var dateBinding: Binding<Date> {
        Binding(get: { DateKey.date(fromDay: draft.date) ?? Date() }, set: { draft.date = DateKey.day($0) })
    }

    // MARK: receipt

    var receiptSection: some View {
        Section {
            if reading {
                HStack { ProgressView(); Text("Reading the receipt…") }
            } else {
                HStack {
                    Button {
                        if AppConfig.flag("-fake-receipt") { Task { await readSample() } } else { showScanner = true }
                    } label: { Label("Scan receipt", systemImage: "doc.viewfinder") }
                        .buttonStyle(.borderless) // two buttons in one row: each must react on its own
                        .accessibilityIdentifier("scanReceipt")
                    Spacer()
                    PhotosPicker(selection: $photoItem, matching: .images) { Label("From photos", systemImage: "photo") }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Receipt from photos")
                }
            }
            if let rid = draft.receiptId { ReceiptThumbnail(receiptId: rid) }
            if let readNote { Text(readNote).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("readNote") }
            ForEach($draft.lines) { $line in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Item", text: $line.name).accessibilityIdentifier("itemName")
                        TextField("0,00", text: $line.priceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .accessibilityIdentifier("itemPrice")
                    }
                    ComparisonBadge(comparison: draft.comparison(for: line, in: model.s))
                }
            }
            .onDelete { draft.lines.remove(atOffsets: $0) }
            if !draft.lines.isEmpty || draft.receiptId != nil {
                Button { draft.lines.append(.init(name: "", priceText: "")) } label: { Label("Add item", systemImage: "plus") }
                if !draft.lines.isEmpty {
                    HStack {
                        Text("Items add up to")
                        Spacer()
                        Text(model.money(draft.linesTotal)).monospacedDigit()
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Receipt")
        } footer: {
            Text("The receipt is read on this phone; nothing is sent anywhere to read it. Each item is compared with the last time you bought it.")
        }
    }

    func read(_ image: UIImage) async {
        reading = true
        defer { reading = false }
        if let jpeg = ReceiptImage.jpeg(image), let id = try? model.photos.save(jpeg) {
            if let old = draft.receiptId, !old.hasPrefix("cloud:") { model.photos.delete(old) }
            draft.receiptId = id
        }
        do {
            let text = try await ReceiptReader.read(image)
            apply(text)
        } catch {
            readNote = "Could not read the text. You can still type the items, and the photo is kept."
        }
    }

    /// UI tests (the simulator has no camera): read a sample Mercator receipt instead.
    func readSample() async {
        apply("""
        MERCATOR d.o.o.
        MLEKO ALPSKO 3,5% 1L        1,29 C
        KRUH BELI 500G              1,49 C
        SKUPAJ EUR                  2,78
        """)
    }

    func apply(_ text: String) {
        let n = draft.applyReceiptText(text)
        if draft.categoryId == nil, let groceries = categories.first(where: { $0.name == "Groceries" }) { draft.categoryId = groceries.id }
        readNote = n == 0 ? "No items found. Try a straighter photo with good light, or type them in."
            : "Found \(n) item\(n == 1 ? "" : "s"). Check them; tap to fix a name or price."
    }

    func save() {
        do {
            let deletedMeanwhile = draft.wasDeletedMeanwhile(in: model.store)
            try draft.save(to: model.store)
            if deletedMeanwhile { savedAsNew = true } else { dismiss() }
        } catch {
            problem = error.localizedDescription
        }
    }
}

struct ComparisonBadge: View {
    @Environment(AppModel.self) private var model
    let comparison: EntryDraft.Comparison?

    var body: some View {
        switch comparison {
        case nil: EmptyView()
        case .new?: Text("First time").font(.caption).foregroundStyle(.secondary)
        case .same(let before, let date)?:
            Text("Same as \(Self.day(date)) (\(model.money(before)))").font(.caption).foregroundStyle(.secondary)
        case .up(let pct, let before, let date)?:
            Text("▲ +\(Self.pct(pct))% since \(Self.day(date)) (was \(model.money(before)))").font(.caption).foregroundStyle(.red)
        case .down(let pct, let before, let date)?:
            Text("▼ \(Self.pct(pct))% since \(Self.day(date)) (was \(model.money(before)))").font(.caption).foregroundStyle(.green)
        }
    }

    static func day(_ key: String) -> String {
        DateKey.date(fromDay: key)?.formatted(.dateTime.day().month(.abbreviated)) ?? key
    }
    static func pct(_ p: Double) -> String { p.formatted(.number.precision(.fractionLength(0...1))) }
}

struct ReceiptThumbnail: View {
    @Environment(AppModel.self) private var model
    let receiptId: String
    @State private var image: UIImage?
    @State private var showFull = false

    var body: some View {
        Group {
            if let image {
                Button { showFull = true } label: {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 140).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel("Receipt photo")
            } else {
                Label("Receipt photo", systemImage: "doc.text.image").foregroundStyle(.secondary)
            }
        }
        .task(id: receiptId) {
            let data = await model.photoData(receiptId)
            image = data.flatMap(UIImage.init(data:))
        }
        .sheet(isPresented: $showFull) {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding().presentationDragIndicator(.visible)
            }
        }
    }
}
