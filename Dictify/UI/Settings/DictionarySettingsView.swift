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
        return entries.filter { $0.term.localizedCaseInsensitiveContains(searchText) }
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
                                subtitle: nil,
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
    private let existingId: UUID?
    let isDuplicate: (String) -> Bool
    let onSave: (DictionaryEntry) -> Void
    let onCancel: () -> Void

    init(entry: DictionaryEntry? = nil, isDuplicate: @escaping (String) -> Bool, onSave: @escaping (DictionaryEntry) -> Void, onCancel: @escaping () -> Void) {
        _term = State(initialValue: entry?.term ?? "")
        _category = State(initialValue: entry?.category ?? "general")
        existingId = entry?.id
        self.isDuplicate = isDuplicate
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var trimmedTerm: String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var isDup: Bool {
        !trimmedTerm.isEmpty && isDuplicate(trimmedTerm)
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
                        category: category
                    )
                    onSave(entry)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTerm.isEmpty || isDup)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(minWidth: 360, idealWidth: 420, minHeight: 280, idealHeight: 320)
    }
}
