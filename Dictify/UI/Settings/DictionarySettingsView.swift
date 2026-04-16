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
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                TextField("Search terms...", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Spacer()

                Button(action: { showingAddSheet = true }) {
                    Label("Add Term", systemImage: "plus")
                }
            }
            .padding()

            Divider()

            // List
            if filteredEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "book.closed")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No dictionary terms")
                        .foregroundStyle(.secondary)
                    Text("Add custom terms to improve transcription accuracy")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredEntries) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.term)
                                    .font(.body.weight(.medium))
                                HStack(spacing: 8) {
                                    Text(entry.category)
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.blue.opacity(0.1))
                                        .clipShape(Capsule())
                                    if let hint = entry.phoneticHint {
                                        Text("[\(hint)]")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            Spacer()

                            Button(action: { editingEntry = entry }) {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)

                            Button(action: { store?.remove(entry) }) {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            DictionaryEntryEditor(
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
    @State private var phoneticHint: String
    private let existingId: UUID?
    let onSave: (DictionaryEntry) -> Void
    let onCancel: () -> Void

    init(entry: DictionaryEntry? = nil, onSave: @escaping (DictionaryEntry) -> Void, onCancel: @escaping () -> Void) {
        _term = State(initialValue: entry?.term ?? "")
        _category = State(initialValue: entry?.category ?? "general")
        _phoneticHint = State(initialValue: entry?.phoneticHint ?? "")
        existingId = entry?.id
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(existingId != nil ? "Edit Term" : "Add Term")
                .font(.headline)

            Form {
                TextField("Term", text: $term)
                Picker("Category", selection: $category) {
                    Text("General").tag("general")
                    Text("Technical").tag("technical")
                    Text("Names").tag("names")
                    Text("Brand").tag("brand")
                }
                TextField("Phonetic Hint (optional)", text: $phoneticHint)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    let entry = DictionaryEntry(
                        id: existingId ?? UUID(),
                        term: term,
                        category: category,
                        phoneticHint: phoneticHint.isEmpty ? nil : phoneticHint
                    )
                    onSave(entry)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(term.isEmpty)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(width: 400, height: 300)
    }
}
