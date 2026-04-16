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
            HStack {
                TextField("Search snippets...", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Spacer()

                Button(action: { showingAddSheet = true }) {
                    Label("Add Snippet", systemImage: "plus")
                }
            }
            .padding()

            Divider()

            if filteredSnippets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No snippets")
                        .foregroundStyle(.secondary)
                    Text("Create snippets to expand spoken cues into full text")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredSnippets) { snippet in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(snippet.cue)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.blue)
                                Text(snippet.body)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text(snippet.category)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.purple.opacity(0.1))
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
                    }
                }
            }
        }
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

                Picker("Category", selection: $category) {
                    Text("General").tag("general")
                    Text("Meetings").tag("meetings")
                    Text("Email").tag("email")
                    Text("Code").tag("code")
                }

                VStack(alignment: .leading) {
                    Text("Snippet Body")
                        .font(.caption)
                    TextEditor(text: $snippetBody)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 100)
                        .border(Color.secondary.opacity(0.2))
                }

                Text("Variables: {{date}}, {{time}}, {{clipboard}}")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

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
        .frame(width: 450, height: 400)
    }
}
