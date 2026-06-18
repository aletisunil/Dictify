import SwiftUI

struct SnippetsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAddSheet = false
    @State private var editingSnippet: Snippet?
    @State private var searchText = ""

    private var store: SnippetStore? { appState.snippetStore }

    private var filteredSnippets: [Snippet] {
        guard let snippets = store?.snippets else { return [] }
        if searchText.isEmpty { return snippets }
        return snippets.filter {
            $0.cue.localizedCaseInsensitiveContains(searchText) ||
            $0.body.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = store?.lastSaveError {
                HomeBanner(
                    icon: "exclamationmark.triangle.fill",
                    tint: .appAlert,
                    title: "Could not save snippets",
                    message: error.localizedDescription
                )
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }

            HStack {
                SearchField(placeholder: "Search snippets...", text: $searchText)

                Spacer()

                Button(action: { showingAddSheet = true }) {
                    Label("Add Snippet", systemImage: "plus")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            if filteredSnippets.isEmpty {
                EmptyStateCard(
                    icon: searchText.isEmpty ? "doc.text" : "magnifyingglass",
                    title: searchText.isEmpty ? "No snippets" : "No matches",
                    subtitle: searchText.isEmpty
                        ? "Create snippets to expand spoken cues into full text."
                        : "Try a different search term."
                )
                .padding(24)
                Spacer()
            } else {
                List {
                    ForEach(filteredSnippets) { snippet in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(snippet.cue)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(snippet.body)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text(snippet.category)
                                    .font(.caption2)
                                    .foregroundStyle(Color.appAccent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.appAccent.opacity(0.12))
                                    .clipShape(Capsule())
                            }

                            Spacer()

                            Button(action: { editingSnippet = snippet }) {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)

                            Button(action: { store?.remove(snippet) }) {
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
            SnippetEditor(
                onSave: { snippet in
                    store?.add(snippet)
                    showingAddSheet = false
                },
                onCancel: { showingAddSheet = false }
            )
        }
        .sheet(item: $editingSnippet) { snippet in
            SnippetEditor(
                snippet: snippet,
                onSave: { updated in
                    store?.update(updated)
                    editingSnippet = nil
                },
                onCancel: { editingSnippet = nil }
            )
        }
    }
}

struct SnippetEditor: View {
    @State private var cue: String
    @State private var snippetBody: String
    @State private var category: String
    private let existingId: UUID?
    let onSave: (Snippet) -> Void
    let onCancel: () -> Void

    init(snippet: Snippet? = nil, onSave: @escaping (Snippet) -> Void, onCancel: @escaping () -> Void) {
        _cue = State(initialValue: snippet?.cue ?? "")
        _snippetBody = State(initialValue: snippet?.body ?? "")
        _category = State(initialValue: snippet?.category ?? "general")
        existingId = snippet?.id
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(existingId != nil ? "Edit Snippet" : "Add Snippet")
                .font(.headline)

            Form {
                TextField("Spoken Cue (e.g., \"calendar link\")", text: $cue)
                    .creamFormRow()

                Picker("Category", selection: $category) {
                    Text("General").tag("general")
                    Text("Meetings").tag("meetings")
                    Text("Email").tag("email")
                    Text("Code").tag("code")
                }
                .creamFormRow()

                VStack(alignment: .leading) {
                    Text("Snippet Body")
                        .font(.caption)
                    TextEditor(text: $snippetBody)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 100)
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

                Text("Variables: {{date}}, {{time}}, {{clipboard}}")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .creamFormRow()
            }
            .formStyle(.grouped)
            .creamFormBackground()

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    let snippet = Snippet(
                        id: existingId ?? UUID(),
                        cue: cue,
                        body: snippetBody,
                        category: category
                    )
                    onSave(snippet)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(cue.isEmpty || snippetBody.isEmpty)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(minWidth: 420, idealWidth: 480, minHeight: 380, idealHeight: 440)
    }
}
