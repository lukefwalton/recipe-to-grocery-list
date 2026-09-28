import SwiftUI
import LFWDesignSystem

@main
struct RecipeToGroceryListApp: App {
    /// One store for the whole app, built once at launch: open SQLite, migrate,
    /// seed. Held as optional state so the UI can show a loading or an honest error
    /// surface instead of crashing if the on-device database can't be opened —
    /// the workout app's bootstrap (`WorkoutChatLog/App/WorkoutChatLogApp.swift`
    /// @5bffddfb80fc). The model is a class held in `@State` (not `@StateObject`)
    /// because it does not exist until the store does; `AppRoot` observes it.
    @State private var model: AppModel?
    @State private var startupError: String?

    init() {
        #if DEBUG
        // One-time diagnostic (the word app's): confirm each bundled variable font's
        // real family name + axes. An empty axes map means the .ttf isn't bundled
        // yet (run scripts/fetch_fonts.sh) or LFWTypeface.family doesn't match
        // Core Text — the app then falls back to system faces, by design.
        for face in Theme.bundledTypefaces {
            let family = face.family
            let axes = LFWVariableFont.axes(of: family)
            print("[RecipeToGroceryList] \(face.displayName) family=\(family) registered=\(LFWVariableFont.isRegistered(family)) axes=\(axes.keys.sorted())")
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    AppRoot(model: model)
                } else if let startupError {
                    StartupErrorView(message: startupError)
                } else {
                    LoadingView()
                        .task { await bootstrap() }
                }
            }
        }
    }

    /// `async` only so the `.task` hop onto the main actor is explicit whichever SDK
    /// compiles it (the iOS 17 SDK's `task` closure is not itself main-actor typed).
    @MainActor
    private func bootstrap() async {
        do {
            let store = try AppDatabase.makeStore()
            model = AppModel(store: store)
        } catch {
            startupError = String(describing: error)
        }
    }
}

/// The onboarding gate + the tab shell, with the theme applied at the root — the
/// word app's `WordOfTheDayApp` body + `RootView` (@e829bcc9c0dc). Observes the
/// model so a theme change re-tints the whole tree, and drains the Share Extension
/// inbox on every foreground (§5.1: "the app drains the inbox on foreground").
private struct AppRoot: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    /// Written out because `scenePhase` is a private stored property, which makes the
    /// synthesized memberwise initializer private too — and `private` reaches only the
    /// enclosing declaration, not a sibling type in the same file. Without this,
    /// `AppRoot(model:)` above would not resolve.
    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    /// Onboarding is always dark (it sits on the family's deep-sea gradient, §4.1);
    /// after it, the palette decides. Decided here rather than left to the inner
    /// `.preferredColorScheme(.dark)` alone so the outcome doesn't depend on which
    /// of two preference modifiers wins.
    private var colorScheme: ColorScheme {
        guard model.onboardingComplete else { return .dark }
        return model.theme.palette.isDark ? .dark : .light
    }

    var body: some View {
        Group {
            if model.onboardingComplete {
                RootTabView()
            } else {
                OnboardingView()
            }
        }
        .animation(.easeInOut(duration: 0.4), value: model.onboardingComplete)
        .environmentObject(model)
        .tint(model.theme.colors.accent)
        .preferredColorScheme(colorScheme)
        // `initial: true`: AppRoot mounts only after the async bootstrap, by which
        // time the scene is already `.active` — without it a share made while the
        // app was closed would wait for the next background/foreground cycle.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { model.drainInbox() }
        }
    }
}

/// The first frame while the database opens. Painted on the stored theme (read
/// directly — the model doesn't exist yet) so the launch never flashes a bare
/// system background between the launch colour and the first screen.
private struct LoadingView: View {
    private let theme = SettingsStore.shared.theme

    var body: some View {
        ZStack {
            LFWThemedBackground(config: theme, animated: false)
            ProgressView("Opening your recipes…")
                .tint(theme.colors.primaryText)
                .foregroundStyle(theme.colors.secondaryText)
        }
        .preferredColorScheme(theme.palette.isDark ? .dark : .light)
    }
}

/// Shown only if the local database fails to open — there is no server to fall
/// back to, so the failure is surfaced honestly rather than hidden. Port of the
/// workout app's `StartupErrorView`.
private struct StartupErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't open your recipes", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 10) {
                // Stable, human message in every build; the raw error shows only
                // in debug so release users never see a raw SQLite string.
                Text("Your on-device recipe database couldn't be opened. Reopen the app to try again.")
                #if DEBUG
                Text(message)
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.secondary)
                #endif
            }
        }
    }
}
