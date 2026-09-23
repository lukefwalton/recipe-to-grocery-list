import SwiftUI
import LFWDesignSystem

/// The three-tab shell (spec §4.1): List (default) / Recipes / Add. Selection lives
/// on `AppModel` so a drained Share Extension item, an empty state's deep link
/// ("List → Recipes", "Recipes → Add") or a launch argument can switch tabs from
/// outside the view. The tab bar is recolored to the palette through UIKit's
/// appearance proxy on appear and on every theme change — the word app's
/// `RootView` (`WordOfTheDay/App/RootView.swift` @e829bcc9c0dc).
///
/// The three screens take no arguments: each reads `AppModel` from the environment
/// and reloads on `changeToken`.
struct RootTabView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            ListView()
                .tabItem { Label(AppTab.list.title, systemImage: AppTab.list.icon) }
                .tag(AppTab.list)
            RecipesView()
                .tabItem { Label(AppTab.recipes.title, systemImage: AppTab.recipes.icon) }
                .tag(AppTab.recipes)
            AddView()
                .tabItem { Label(AppTab.add.title, systemImage: AppTab.add.icon) }
                .tag(AppTab.add)
        }
        .tint(model.theme.colors.accent)
        .onAppear { TabBarAppearance.apply(theme: model.theme) }
        .onChange(of: model.theme) { _, theme in TabBarAppearance.apply(theme: theme) }
    }
}
