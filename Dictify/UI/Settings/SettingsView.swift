import SwiftUI

enum SettingsTab: Hashable {
    case general
    case dictionary
    case snippets
    case api
    case about
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: SettingsTab
    private let showMissingGroqAPIKeyWarning: Bool

    init(selectedTab: SettingsTab = .general, showMissingGroqAPIKeyWarning: Bool = false) {
        _selectedTab = State(initialValue: selectedTab)
        self.showMissingGroqAPIKeyWarning = showMissingGroqAPIKeyWarning
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .environmentObject(appState)
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(SettingsTab.general)

            DictionarySettingsView()
                .environmentObject(appState)
                .tabItem {
                    Label("Dictionary", systemImage: "book")
                }
                .tag(SettingsTab.dictionary)

            SnippetsSettingsView()
                .environmentObject(appState)
                .tabItem {
                    Label("Snippets", systemImage: "doc.text")
                }
                .tag(SettingsTab.snippets)

            APISettingsView(showMissingGroqAPIKeyWarning: showMissingGroqAPIKeyWarning)
                .environmentObject(appState)
                .tabItem {
                    Label("API", systemImage: "key")
                }
                .tag(SettingsTab.api)

            AboutSettingsView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag(SettingsTab.about)
        }
        .frame(minWidth: 550, idealWidth: 580, minHeight: 450, idealHeight: 500)
    }
}
