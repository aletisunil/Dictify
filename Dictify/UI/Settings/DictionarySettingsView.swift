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
            if let error = store?.lastSaveError {
                HomeBanner(
                    icon: "exclamationmark.triangle.fill",
                    tint: .appAlert,
                    title: "Could not save dictionary",
                    message: error.localizedDescription
                )
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }

            // Toolbar
            HStack {
                SearchField(placeholder: "Search terms...", text: $searchText)

                Spacer()

                Button(action: { showingAddSheet = true }) {
                    Label("Add Term", systemImage: "plus")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            // List
            if filteredEntries.isEmpty {
                EmptyStateCard(
                    icon: searchText.isEmpty ? "book.closed" : "magnifyingglass",
                    title: searchText.isEmpty ? "No dictionary terms" : "No matches",
                    subtitle: searchText.isEmpty
                        ? "Add custom terms to improve transcription accuracy."
                        : "Try a different search term."
                )
                .padding(24)
                Spacer()
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
                                        .foregroundStyle(Color.appAccent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.appAccent.opacity(0.12))
                                        .clipShape(Capsule())
                                    if entry.source == .learned {
                                        Text("Learned")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.secondary.opacity(0.12))
                                            .clipShape(Capsule())
                                    }
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
                        .listRowBackground(Color.appCardBackground)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.appWindowBackground)
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
                    .creamFormRow()
                Picker("Category", selection: $category) {
                    Text("General").tag("general")
                    Text("Technical").tag("technical")
                    Text("Names").tag("names")
                    Text("Brand").tag("brand")
                }
                .creamFormRow()
                TextField("Phonetic Hint (optional)", text: $phoneticHint)
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
        .frame(minWidth: 360, idealWidth: 420, minHeight: 280, idealHeight: 320)
    }
}
