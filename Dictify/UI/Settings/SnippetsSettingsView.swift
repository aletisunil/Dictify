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

    @AppStorage("refinementEnabled") private var refinementEnabled: Bool = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                if let error = store?.lastSaveError {
                    HomeBanner(
                        icon: "exclamationmark.triangle.fill",
                        tint: .appAlert,
                        title: "Could not save snippets",
                        message: error.localizedDescription
                    )
                }

                DSSectionHeader(
                    title: "Snippets",
                    subtitle: "Speak a cue and Dictify expands it into the full text."
                )

                if !refinementEnabled {
                    InlineHint(
                        icon: "wand.and.stars",
                        text: "Snippets are expanded by AI refinement. Turn on “AI Text Refinement” in General to use them."
                    )
                }

                LibraryToolbar(
                    searchPlaceholder: "Search snippets…",
                    searchText: $searchText,
                    addTitle: "Add Snippet",
                    onAdd: { showingAddSheet = true }
                )

                if filteredSnippets.isEmpty {
                    EmptyStateCard(
                        icon: searchText.isEmpty ? "doc.text" : "magnifyingglass",
                        title: searchText.isEmpty ? "No snippets" : "No matches",
                        subtitle: searchText.isEmpty
                            ? "Create snippets to expand spoken cues into full text."
                            : "Try a different search term."
                    )
                    .frame(maxWidth: .infinity)
                    .dsCard()
                } else {
                    CardGroup {
                        ForEach(Array(filteredSnippets.enumerated()), id: \.element.id) { index, snippet in
                            if index > 0 { Divider().background(Color.appHairline) }
                            LibraryRow(
                                title: snippet.cue,
                                subtitle: snippet.body,
                                badges: { Badge(text: snippet.category) },
                                onEdit: { editingSnippet = snippet },
                                onDelete: { store?.remove(snippet) }
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
            SnippetEditor(
                isDuplicate: { store?.cueExists($0, excluding: nil) ?? false },
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
                isDuplicate: { store?.cueExists($0, excluding: snippet.id) ?? false },
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
    let isDuplicate: (String) -> Bool
    let onSave: (Snippet) -> Void
    let onCancel: () -> Void

    init(snippet: Snippet? = nil, isDuplicate: @escaping (String) -> Bool, onSave: @escaping (Snippet) -> Void, onCancel: @escaping () -> Void) {
        _cue = State(initialValue: snippet?.cue ?? "")
        _snippetBody = State(initialValue: snippet?.body ?? "")
        _category = State(initialValue: snippet?.category ?? "general")
        existingId = snippet?.id
        self.isDuplicate = isDuplicate
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var trimmedCue: String {
        cue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var isDup: Bool {
        !trimmedCue.isEmpty && isDuplicate(trimmedCue)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(existingId != nil ? "Edit Snippet" : "Add Snippet")
                .font(.dsHeadline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Form {
                TextField("Spoken Cue (e.g., \"calendar link\")", text: $cue)
                    .creamFormRow()

                if isDup {
                    Text("A snippet with this cue already exists.")
                        .font(.caption)
                        .foregroundStyle(Color.appAlert)
                        .creamFormRow()
                }

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
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedCue.isEmpty || snippetBody.isEmpty || isDup)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(minWidth: 420, idealWidth: 480, minHeight: 380, idealHeight: 440)
    }
}
