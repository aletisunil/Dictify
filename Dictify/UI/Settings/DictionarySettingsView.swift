import SwiftUI

struct DictionarySettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAddSheet = false
    @State private var editingEntry: DictionaryEntry?
    @State private var searchText = ""

    private var store: DictionaryStore? { appState.dictionaryStore }

    private var filteredEntries: [DictionaryEntry] {
        guard let entries = store?.entries else { return [] }
        if searchText.isEmpty { return entries }
        return entries.filter {
            $0.term.localizedCaseInsensitiveContains(searchText)
                || $0.aliases.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                if let error = store?.lastSaveError {
                    HomeBanner(
                        icon: "exclamationmark.triangle.fill",
                        tint: .appAlert,
                        title: "Could not save dictionary",
                        message: error.localizedDescription
                    )
                }

                DSSectionHeader(
                    title: "Dictionary",
                    subtitle: "Custom terms Dictify favours when transcribing and refining."
                )

                LibraryToolbar(
                    searchPlaceholder: "Search terms…",
                    searchText: $searchText,
                    addTitle: "Add Term",
                    onAdd: { showingAddSheet = true }
                )

                if filteredEntries.isEmpty {
                    EmptyStateCard(
                        icon: searchText.isEmpty ? "book.closed" : "magnifyingglass",
                        title: searchText.isEmpty ? "No dictionary terms" : "No matches",
                        subtitle: searchText.isEmpty
                            ? "Add custom terms to improve transcription accuracy."
                            : "Try a different search term."
                    )
                    .frame(maxWidth: .infinity)
                    .dsCard()
                } else {
                    CardGroup {
                        ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().background(Color.appHairline) }
                            LibraryRow(
                                title: entry.term,
                                subtitle: entry.aliases.isEmpty
                                    ? nil
                                    : "Heard as: \(entry.aliases.joined(separator: ", "))",
                                badges: {
                                    Badge(text: entry.category)
                                },
                                onEdit: { editingEntry = entry },
                                onDelete: { store?.remove(entry) }
                            )
                        }
                    }
                }
            }
            .padding(DS.pageInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.appWindowBackground)
        .sheet(isPresented: $showingAddSheet) {
            DictionaryEntryEditor(
                isDuplicate: { store?.termExists($0, excluding: nil) ?? false },
                aliasesConflict: { store?.aliasesConflict($0, excluding: nil) ?? false },
                onSave: { entry in
                    store?.add(entry)
                    showingAddSheet = false
                },
                onCancel: { showingAddSheet = false }
            )
        }
        .sheet(item: $editingEntry) { entry in
            DictionaryEntryEditor(
                entry: entry,
                isDuplicate: { store?.termExists($0, excluding: entry.id) ?? false },
                aliasesConflict: { store?.aliasesConflict($0, excluding: entry.id) ?? false },
                onSave: { updated in
                    store?.update(updated)
                    editingEntry = nil
                },
                onCancel: { editingEntry = nil }
            )
        }
    }
}

struct DictionaryEntryEditor: View {
    @State private var term: String
    @State private var category: String
    @State private var aliasesText: String
    private let existingId: UUID?
    private let originalAddedAt: Date
    private let originalUseCount: Int
    private let originalLastUsedAt: Date?
    let isDuplicate: (String) -> Bool
    let aliasesConflict: ([String]) -> Bool
    let onSave: (DictionaryEntry) -> Void
    let onCancel: () -> Void

    init(
        entry: DictionaryEntry? = nil,
        isDuplicate: @escaping (String) -> Bool,
        aliasesConflict: @escaping ([String]) -> Bool,
        onSave: @escaping (DictionaryEntry) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _term = State(initialValue: entry?.term ?? "")
        _category = State(initialValue: entry?.category ?? "general")
        _aliasesText = State(initialValue: entry?.aliases.joined(separator: "\n") ?? "")
        existingId = entry?.id
        originalAddedAt = entry?.addedAt ?? Date()
        originalUseCount = entry?.useCount ?? 0
        originalLastUsedAt = entry?.lastUsedAt
        self.isDuplicate = isDuplicate
        self.aliasesConflict = aliasesConflict
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var trimmedTerm: String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var isDup: Bool {
        !trimmedTerm.isEmpty && isDuplicate(trimmedTerm)
    }
    private var aliases: [String] {
        aliasesText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    private var hasAliasConflict: Bool {
        let keys = aliases.map { $0.lowercased() }
        return Set(keys).count != keys.count
            || aliasesConflict(aliases)
            || aliases.contains { $0.caseInsensitiveCompare(trimmedTerm) == .orderedSame }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(existingId != nil ? "Edit Term" : "Add Term")
                .font(.dsHeadline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Form {
                CreamTextField(placeholder: "Term", text: $term)
                    .creamFormRow()
                if isDup {
                    Text("A term with this name already exists.")
                        .font(.caption)
                        .foregroundStyle(Color.appAlert)
                        .creamFormRow()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Heard As (one mishearing per line)")
                        .font(.caption)
                    TextEditor(text: $aliasesText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 76)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color.appCardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2))
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .creamFormRow()
                if hasAliasConflict {
                    Text("A mishearing is duplicated or already belongs to another term.")
                        .font(.caption)
                        .foregroundStyle(Color.appAlert)
                        .creamFormRow()
                }
                Picker("Category", selection: $category) {
                    Text("General").tag("general")
                    Text("Technical").tag("technical")
                    Text("Names").tag("names")
                    Text("Brand").tag("brand")
                }
                .creamFormRow()
            }
            .formStyle(.grouped)
            .creamFormBackground()

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    let entry = DictionaryEntry(
                        id: existingId ?? UUID(),
                        term: term,
                        category: category,
                        addedAt: originalAddedAt,
                        aliases: aliases,
                        useCount: originalUseCount,
                        lastUsedAt: originalLastUsedAt
                    )
                    onSave(entry)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTerm.isEmpty || isDup || hasAliasConflict)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(minWidth: 400, idealWidth: 460, minHeight: 390, idealHeight: 440)
    }
}
